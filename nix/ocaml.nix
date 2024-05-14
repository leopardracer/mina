# A set defining OCaml parts&dependencies of Minaocamlnix
{ inputs, ... }@args:
let
  opam-nix = inputs.opam-nix.lib.${pkgs.system};

  inherit (args) pkgs;

  inherit (pkgs.lib)
    hasPrefix last getAttrs filterAttrs optionalAttrs makeBinPath optionalString
    escapeShellArg;

  repos = with inputs; [ o1-opam-repository opam-repository ];

  export = opam-nix.importOpam ../opam.export;

  # Dependencies required by every Mina package:
  # Packages which are `installed` in the export.
  # These are all the transitive ocaml dependencies of Mina.
  implicit-deps =
    builtins.removeAttrs (opam-nix.opamListToQuery export.installed)
    [ "check_opam_switch" ];

  # Extra packages which are not in opam.export but useful for development, such as an LSP server.
  extra-packages = with implicit-deps; {
    dune-rpc = "3.5.0";
    dyn = "3.5.0";
    fiber = "3.5.0";
    chrome-trace = "3.5.0";
    ocaml-lsp-server = "1.15.1-4.14";
    ocamlc-loc = "3.5.0";
    ocaml-system = ocaml;
    ocamlformat-rpc-lib = "0.22.4";
    omd = "1.3.2";
    ordering = "3.5.0";
    pp = "1.1.2";
    ppx_yojson_conv_lib = "v0.15.0";
    stdune = "3.5.0";
    xdg = dune;
  };

  implicit-deps-overlay = self: super:
    (if pkgs.stdenv.isDarwin then {
      async_ssl = super.async_ssl.overrideAttrs {
        NIX_CFLAGS_COMPILE =
          "-Wno-implicit-function-declaration -Wno-incompatible-function-pointer-types";
      };
    } else
      { }) // {
        # https://github.com/Drup/ocaml-lmdb/issues/41
        lmdb = super.lmdb.overrideAttrs
          (oa: { buildInputs = oa.buildInputs ++ [ self.conf-pkg-config ]; });

        # Doesn't have an explicit dependency on ctypes-foreign
        ctypes = super.ctypes.overrideAttrs
          (oa: { buildInputs = oa.buildInputs ++ [ self.ctypes-foreign ]; });

        # Can't find sodium-static and ctypes
        sodium = super.sodium.overrideAttrs {
          NIX_CFLAGS_COMPILE = "-I${pkgs.sodium-static.dev}/include";
          propagatedBuildInputs = [ pkgs.sodium-static ];
          preBuild = ''
            export LD_LIBRARY_PATH="${super.ctypes}/lib/ocaml/${super.ocaml.version}/site-lib/ctypes";
          '';
        };

        rocksdb_stubs = super.rocksdb_stubs.overrideAttrs {
          MINA_ROCKSDB = "${pkgs.rocksdb-mina}/lib/librocksdb.a";
        };

        # This is needed because
        # - lld package is not wrapped to pick up the correct linker flags
        # - bintools package also includes as which is incompatible with gcc
        lld_wrapped = pkgs.writeShellScriptBin "ld.lld"
          ''${pkgs.llvmPackages.bintools}/bin/ld.lld "$@"'';

        core =
          super.core.overrideAttrs { propagatedBuildInputs = [ pkgs.tzdata ]; };
      };

  scope =
    opam-nix.applyOverlays (opam-nix.__overlays ++ [ implicit-deps-overlay ])
    (opam-nix.defsToScope pkgs { }
      (opam-nix.queryToDefs repos (extra-packages // implicit-deps)));

  installedPackageNames =
    map (x: (opam-nix.splitNameVer x).name) (builtins.attrNames implicit-deps);

  sourceInfo = inputs.self.sourceInfo or { };

  # "System" dependencies required by all Mina packages
  external-libs = with pkgs;
    [ zlib bzip2 gmp openssl libffi ]
    ++ lib.optional (!(stdenv.isDarwin && stdenv.isAarch64)) jemalloc;

  base-libs =
    let deps = pkgs.lib.getAttrs (builtins.attrNames implicit-deps) scope;
    in pkgs.stdenv.mkDerivation {
      name = "mina-base-libs";
      phases = [ "installPhase" ];
      buildInputs = builtins.attrValues deps;
      installPhase = ''
        mkdir -p $out/lib/ocaml/${scope.ocaml.version}/site-lib/stublibs $out/nix-support $out/bin
        {
          echo -n 'export OCAMLPATH=$'
          echo -n '{OCAMLPATH-}$'
          echo '{OCAMLPATH:+:}'"$out/lib/ocaml/${scope.ocaml.version}/site-lib"
          echo -n 'export CAML_LD_LIBRARY_PATH=$'
          echo -n '{CAML_LD_LIBRARY_PATH-}$'
          echo '{CAML_LD_LIBRARY_PATH:+:}'"$out/lib/ocaml/${scope.ocaml.version}/site-lib/stublibs"
        } > $out/nix-support/setup-hook
        for input in $buildInputs; do
          [ ! -d "$input/lib/ocaml/${scope.ocaml.version}/site-lib" ] || {
            find "$input/lib/ocaml/${scope.ocaml.version}/site-lib" -maxdepth 1 -mindepth 1 -not -name stublibs | while read d; do
              ln -s "$d" "$out/lib/ocaml/${scope.ocaml.version}/site-lib/"
            done
          }
          [ ! -d "$input/lib/ocaml/${scope.ocaml.version}/site-lib/stublibs" ] || cp -Rs "$input/lib/ocaml/${scope.ocaml.version}/site-lib/stublibs"/* "$out/lib/ocaml/${scope.ocaml.version}/site-lib/stublibs/"
          [ ! -d "$input/bin" ] || cp -Rs $input/bin/* $out/bin
          [ ! -f "$input/nix-support/propagated-build-inputs" ] || { cat "$input/nix-support/propagated-build-inputs" | sed -r 's/\s//g'; echo ""; } >> $out/nix-support/propagated-build-inputs.draft
          echo $input >> $out/nix-support/propagated-build-inputs.ref
        done
        sort $out/nix-support/propagated-build-inputs.draft | uniq | grep -vE '^$' > $out/nix-support/propagated-build-inputs.draft.unique
        sort $out/nix-support/propagated-build-inputs.ref | uniq | grep -vE '^$' > $out/nix-support/propagated-build-inputs.ref.unique
        comm -2 -3 $out/nix-support/propagated-build-inputs.{draft,ref}.unique > $out/nix-support/propagated-build-inputs
        rm $out/nix-support/propagated-build-inputs.*
      '';
    };

  # Some attrsets helpers
  attrFold = f: acc: attrs:
    builtins.foldl' (acc: { fst, snd }: f acc fst snd) acc
    (pkgs.lib.zipLists (builtins.attrNames attrs) (builtins.attrValues attrs));
  attrAll = f: attrFold (acc: key: value: acc && f key value) true;
  setAttrByPath' = val: attrs: path:
    if path == [ ] then
      val
    else
      let
        hd = builtins.head path;
        tl = builtins.tail path;
      in attrs // { "${hd}" = setAttrByPath' val (attrs."${hd}" or { }) tl; };

  dune-description = pkgs.stdenv.mkDerivation {
    pname = "dune-description";
    version = "dev";
    src = pkgs.lib.sources.sourceFilesBySuffices ../src [
      "dune"
      "dune-project"
      ".inc"
      ".opam"
    ];
    phases = [ "unpackPhase" "buildPhase" ];
    buildPhase = ''
      files=$(ls)
      mkdir src
      mv $files src
      cp ${../dune} dune
      cp ${../dune-project} dune-project
      ${
        inputs.describe-dune.defaultPackage.${pkgs.system}
      }/bin/describe-dune > $out
    '';
  };

  duneDescLoaded = builtins.fromJSON (builtins.readFile dune-description);

  quote = builtins.replaceStrings [ "." "/" ] [ "__" "-" ];

  # Mapping packages: pkg -> { lib: {public_name|name -> loc}, exe: {..}, test: {..} }
  # Mapping lib2Pkg: lib -> pkg (from library name to package)
  # Mapping pubNames: lib's name -> lib's public_name (if such exists)
  # Mapping exes: .exe path -> { package, name }
  # Mapping srcInfo: src -> entry from dune description w/o units
  # Mapping fileOuts2Src: file path -> src (mapping from output of some dune's rule
  #                                         to directory that contains dune file)
  # Mapping pseudoPackages: pkg -> src (for packages which names were artifically generated
  #                                     to hold units that have no package defined)
  info = let
    extendAccDef = defVal: name: val: acc:
      acc // {
        "${name}" = if acc ? "${name}" then defVal else val;
      };
    extendAccImpl = msg: name: val: acc:
      acc // {
        "${name}" = if acc ? "${name}" then builtins.throw msg else val;
      };
    extendAcc = pkg: name:
      extendAccImpl
      "Unit with package ${pkg} name ${name} is defined in multiple dune files"
      name;
    handleFileDepMaps = el:
      { fileOuts2Src, srcInfo, ... }@acc:
      let
        fileOuts2Src' = builtins.foldl' (acc': out:
          extendAccImpl "Output ${out} appears twice in dune files" out el.src
          acc') fileOuts2Src (builtins.attrNames el.file_outs);
        srcInfo' =
          extendAccImpl "Source ${el.src} appears twice in dune description"
          el.src (builtins.removeAttrs el [ "units" "src" ]) srcInfo;
      in acc // {
        fileOuts2Src = fileOuts2Src';
        srcInfo = srcInfo';
      };
    extendAccLib = src:
      { packages, lib2Pkg, pubNames, exes, pseudoPackages, ... }@acc:
      unit:
      let
        pkg = if unit ? "package" then
          unit.package
        else if unit ? "public_name" && unit.type == "lib" then
          builtins.head (pkgs.lib.splitString "." unit.public_name)
        else
          "__${quote src}__";
        isPseudoPkg = !(unit ? "package")
          && !(unit ? "public_name" && unit.type == "lib");
        name = if unit ? "public_name" then unit.public_name else unit.name;
        unitInfo = unit // { inherit src; };
        packages' = if packages ? "${pkg}" then
          packages // {
            "${pkg}" = packages."${pkg}" // {
              "${unit.type}" =
                extendAcc pkg name unitInfo packages."${pkg}"."${unit.type}";
            };
          }
        else
          packages // {
            "${pkg}" = {
              lib = { };
              exe = { };
              test = { };
            } // {
              "${unit.type}" = { "${name}" = unitInfo; };
            };
          };
        lib2Pkg' = if unit.type == "lib" then
          extendAcc pkg name pkg lib2Pkg
        else
          lib2Pkg;
        pubNames' = if unit.type == "lib" && unit ? "public_name" then
          extendAccDef "" unit.name unit.public_name pubNames
        else
          pubNames;
        exes' = if unit.type == "exe" then
          extendAcc pkg "${src}/${unit.name}.exe" {
            package = pkg;
            inherit name;
          } exes
        else
          exes;
        pseudoPackages' = if isPseudoPkg then
          pseudoPackages // { "${pkg}" = src; }
        else
          pseudoPackages;
      in acc // {
        packages = packages';
        lib2Pkg = lib2Pkg';
        pubNames = pubNames';
        exes = exes';
        pseudoPackages = pseudoPackages';
      };
    foldF = acc0: el:
      handleFileDepMaps el
      (builtins.foldl' (extendAccLib el.src) acc0 el.units);
  in builtins.foldl' foldF {
    packages = { };
    lib2Pkg = { };
    pubNames = { };
    exes = { };
    srcInfo = { };
    fileOuts2Src = { };
    pseudoPackages = { };
  } duneDescLoaded;

  executePromote = { pkgs, libs, ... }@deps:
    promoted:
    deps // {
      pkgs = pkgs // args.pkgs.lib.genAttrs promoted (_: { });
      libs = builtins.removeAttrs libs promoted;
    };

  # Dep entry:
  # { libs : <pkg> -> <name> -> {}
  # , pkgs: <pkg> -> {}
  # , exes : <pkg> -> <name> -> {}
  # , files: <file's dune root> -> {}
  # }
  #
  # Deps:
  # { units: { <pkg> -> <lib|exe|test> -> <name> -> <dep entry> }
  # , files: { <file's dune root> -> { exes: ..., files: ...  } }
  # }
  allDepKeys = directDeps:
    let
      impl = deps: type:
        builtins.concatLists (pkgs.lib.mapAttrsToList (package: entries:
          builtins.map (name: { inherit name package type; })
          (builtins.attrNames entries)) deps);
    in builtins.map (src: {
      type = "file";
      inherit src;
    }) (builtins.attrNames (directDeps.files or { }))
    ++ impl (directDeps.exes or { }) "exe"
    ++ impl (directDeps.libs or { }) "lib";

  allUnitKeys = allUnits:
    builtins.concatLists (pkgs.lib.mapAttrsToList (package: units0:
      builtins.concatLists (pkgs.lib.mapAttrsToList (type: units:
        builtins.map (name: { inherit type name package; })
        (builtins.attrNames units)) units0)) allUnits);

  directFileDeps = dfArgs: src:
    let
      handleDirectDep = { exes, files }@acc:
        dep:
        if info.exes ? "${dep}" then
          let exe = info.exes."${dep}";
          in if dfArgs ? forExe && dfArgs.forExe == exe.name then
            acc
          else
            pkgs.lib.recursiveUpdate acc {
              exes."${exe.package}"."${exe.name}" = { };
            }
        else if info.fileOuts2Src ? "${dep}" then
          let depSrc = info.fileOuts2Src."${dep}";
          in if depSrc == src then
            acc
          else {
            inherit exes;
            files = files // { "${depSrc}" = { }; };
          }
        else
          acc;
      empty = {
        exes = { };
        files = { };
      };
      file_deps = info.srcInfo."${src}".file_deps;
      deps = builtins.foldl' handleDirectDep empty file_deps;
      duneDirs = builtins.concatMap (fd:
        if builtins.baseNameOf fd == "dune" then
          [ (builtins.dirOf fd) ]
        else
          [ ]) file_deps;
    in deps // { files = builtins.removeAttrs deps.files duneDirs; };

  depByKey = { files, units }:
    { type, ... }@key:
    if type == "file" then
      files."${key.src}"
    else
      units."${key.package}"."${key.type}"."${key.name}";

  computeDepsImpl = acc0: path: directDeps:
    let
      recLoopMsg = "Recursive loop in ${builtins.concatStringsSep "." path}";
      acc1 = setAttrByPath' (throw recLoopMsg) acc0 path;
      directKeys = allDepKeys directDeps;
      acc2 = builtins.foldl' computeDeps acc1 directKeys;
      exes = builtins.foldl' (acc': key:
        let subdeps = depByKey acc2 key;
        in pkgs.lib.recursiveUpdate (subdeps.exes or { }) acc') directDeps.exes
        directKeys;
      files = builtins.foldl' (acc': key:
        let subdeps = depByKey acc2 key;
        in pkgs.lib.recursiveUpdate (subdeps.files or { }) acc')
        directDeps.files directKeys;
      libsAndPkgs = builtins.foldl' (acc': key:
        if key.type == "lib" then
          let
            subdeps = depByKey acc2 key;
            update = {
              libs = subdeps.libs or { };
              pkgs = subdeps.pkgs or { };
            };
          in pkgs.lib.recursiveUpdate update acc'
        else
          acc') {
            libs = directDeps.libs or { };
            pkgs = directDeps.pkgs or { };
          } directKeys;
      depMap = libsAndPkgs // { inherit exes files; };
      promote_ = pkg: libs:
        let
          pkgDef = info.packages."${pkg}";
          libs_ = builtins.attrNames libs;
          rem = builtins.removeAttrs pkgDef.lib libs_;
          trivialCase = rem == { } && pkgDef.test == { } && pkgDef.exe == { };
        in if trivialCase then [ pkg ] else [ ];
      promoted =
        builtins.concatLists (pkgs.lib.mapAttrsToList promote_ depMap.libs);
      depMap' = executePromote depMap promoted;
    in setAttrByPath' depMap' acc2 path;

  directLibDeps = let
    toPubName = d:
      let d' = info.pubNames."${d}" or "";
      in if d' == "" then d else d';
    implementsDep = unit:
      if unit ? "implements" then [ unit.implements ] else [ ];
    defImplDeps = unit:
      if unit ? "default_implementation" then
        let
          defImplLib = toPubName unit.default_implementation;
          defImplPkg = info.lib2Pkg."${defImplLib}";
        in builtins.map toPubName
        info.packages."${defImplPkg}".lib."${defImplLib}".deps
      else
        [ ];
    mkDep = name: {
      inherit name;
      type = "lib";
      package = info.lib2Pkg."${name}";
    };
    libs = deps:
      builtins.foldl' (acc: name:
        if info.lib2Pkg ? "${name}" then
          pkgs.lib.recursiveUpdate acc {
            "${info.lib2Pkg."${name}"}"."${name}" = { };
          }
        else
          acc) { } deps;
  in unit: {
    libs = libs (defImplDeps unit ++ implementsDep unit
      ++ builtins.map toPubName unit.deps);
  };

  computeDeps = { files, units }@acc:
    { type, ... }@self:
    if type == "file" then
      if files ? "${self.src}" then
        acc
      else
        computeDepsImpl acc [ "files" self.src ] (directFileDeps { } self.src)
    else if units ? "${self.package}"."${self.type}"."${self.name}" then
      acc
    else
      let
        unit = info.packages."${self.package}"."${self.type}"."${self.name}";
        dfArgs = if self.type == "exe" then { forExe = unit.name; } else { };
        directDeps = directFileDeps dfArgs unit.src // directLibDeps unit;
      in computeDepsImpl acc [ "units" self.package self.type self.name ]
      directDeps;

  pruneDepMap = let
    pruneListDeps = acc: field:
      if acc ? "${field}" then
        acc // { "${field}" = builtins.attrNames acc."${field}"; }
      else
        acc;
    pruneMultiDeps = acc: field:
      if acc ? "${field}" then
        acc // {
          "${field}" = builtins.mapAttrs (_: builtins.attrNames) acc."${field}";
        }
      else
        acc;
  in with pkgs.lib;
  (flip pkgs.lib.pipe [
    (filterAttrs (_: val: val != { }))
    (flip (builtins.foldl' pruneListDeps) [ "files" "pkgs" ])
    (flip (builtins.foldl' pruneMultiDeps) [ "exes" "libs" ])
  ]);

  allDepsToJSON = { files, units }:
    builtins.toJSON {
      files = builtins.mapAttrs (_: pruneDepMap) files;
      units = builtins.mapAttrs (_: # iterating packages
        builtins.mapAttrs (_: # iterating types
          builtins.mapAttrs (_: # iterating names
            pruneDepMap))) units;
    };

  allDepsNotFullyPromoted = builtins.foldl' computeDeps {
    files = { };
    units = { };
  } (allUnitKeys info.packages);

  # Trying to make ${depPkg} a package dependency instead of
  # having individual libs ${depLibs} as dependencies
  promote = allNotPromoted: pkg: type: name: depPkg: depLibs:
    if pkg == depPkg then
      [ ] # Don't promote dependencies from own package
    else
      let
        # We want to test that $pkg.$type.$name isn't a dependency of:
        #  * any of ${depPkg}'s libraries
        #  * any of executable depedendencies of package's libraries
        depPkgDef = info.packages."${depPkg}";
        depLibNames = builtins.attrNames depLibs;
        depLibs' =
          builtins.attrNames (builtins.removeAttrs depPkgDef.lib depLibNames);
        depTests = builtins.attrNames depPkgDef.test;
        depExes = builtins.attrNames depPkgDef.exe;
        collectExes = type: acc: name:
          pkgs.lib.recursiveUpdate acc
          (allNotPromoted.units."${depPkg}"."${type}"."${name}".exes or { });
        collectStep = type: names: acc:
          builtins.foldl' (collectExes type) acc names;
        depTransExes = pkgs.lib.pipe { "${depPkg}" = depPkgDef.exe; } [
          (collectStep "lib" depLibs')
          (collectStep "test" depTests)
          (collectStep "exe" depExes)
        ];
        kicksNoCycle = type': pkg': name':
          !(allNotPromoted.units
            ? "${pkg'}"."${type'}"."${name'}".pkgs."${pkg}");
        multi = cycleCheck: type': pkg': names:
          pkgs.lib.all (cycleCheck type' pkg') (builtins.attrNames names);
        libKicksNoCycle = type': pkg': name':
          !(allNotPromoted.units
            ? "${pkg'}"."${type'}"."${name'}".libs."${pkg}"."${name}"
            || allNotPromoted.units
            ? "${pkg'}"."${type'}"."${name'}".pkgs."${pkg}");
        goodToPromote = cycleCheck:
          builtins.foldl' (a: b: a && b) true [
            # Check that $depPkg package's libraries do not have $pkg.$name as a dependency
            (pkgs.lib.all (cycleCheck "lib" depPkg) depLibs')
            # Check that $depPkg package's tests do not have $pkg.$name as a dependency
            (pkgs.lib.all (cycleCheck "test" depPkg) depTests)
            # Check that $depPkg package's executables (or transitive executable dependencies)
            # do not have $pkg.$name as a dependency
            (attrAll (multi cycleCheck "exe") depTransExes)
          ];
        decisionToPromote = if type == "exe" then
          !(depTransExes ? "${pkg}"."${name}") && goodToPromote kicksNoCycle
        else if type == "lib" then
          goodToPromote libKicksNoCycle
        else
          goodToPromote kicksNoCycle;
      in if decisionToPromote then [ depPkg ] else [ ];

  allDeps = attrFold (acc0: pkg:
    attrFold (acc1: type:
      attrFold (acc2: name: depMap:
        let
          promoted = builtins.concatLists
            (pkgs.lib.mapAttrsToList (promote acc2 pkg type name) depMap.libs);
          depMap' = executePromote depMap promoted;
        in setAttrByPath' depMap' acc2 [ "units" pkg type name ]) acc1) acc0)
    allDepsNotFullyPromoted allDepsNotFullyPromoted.units;

  separatedLibs = attrFold (acc0: pkg: units0:
    attrFold (acc1: type: units1:
      attrFold (acc2: name:
        { libs, ... }:
        let
          libs' = builtins.removeAttrs libs [ pkg ];
          mkVal = builtins.mapAttrs (_: builtins.attrNames);
        in if libs' != { } then
          setAttrByPath' (mkVal libs') acc2 [ pkg type name ]
        else
          acc2) acc1 units1) acc0 units0) { } allDeps.units;

  # fileFilter type: object
  #
  # If contains ".", this value is an object describing that files
  # in the directory need to be considered
  #
  # If not provided, only children are traversed

  mergeFiltersDo = filters:
    if builtins.length filters == 1 then
      builtins.head filters
    else
      let
        dots =
          builtins.concatMap (f: if f ? "." then [ f."." ] else [ ]) filters;
      in if dots == [ ] then
        mergeFilters filters
      else
        let someDot = builtins.head dots;
        in if builtins.any (d: someDot != d) dots then
          throw
          "Merging of filters with directories defined at the same level differently is not supported"
        else
        # We overwrite dot so that there is no recursive call
        # to mergeFilters on fields of "." (laziness helps)
          mergeFilters filters // { "." = someDot; };

  mergeFilters = v: pkgs.lib.zipAttrsWith (_: mergeFiltersDo) v;

  dotIncludeAll = { type = 2; };

  # Creates a filter from filepath
  # Assumes that filepath contains no dots
  mkFilter = dot: filepath:
    if filepath == "." then {
      "." = dot;
    } else
      pkgs.lib.setAttrByPath (pkgs.lib.splitString "/" filepath ++ [ "." ]) dot;

  hasExt = fname: ext: pkgs.lib.hasSuffix ("." + ext) fname;
  withinPath = fpath: exc: pkgs.lib.take (builtins.length exc) fpath == exc;

  checkDot = filetype: isParent: path: dot:
    let
      type = dot.type or 1000;
      filename = pkgs.lib.last path;
    in if type == 0 || type == 1 then
      (type == 1 || isParent) && ((type == 1 && filetype == "directory")
        || builtins.any (hasExt filename) dot.ext)
      && !builtins.any (withinPath path) (dot.exclude or [ ])
    else
      type == 2;

  checkAncestors = filetype: filepath: filter:
    let
      latestDotInfo = builtins.foldl' ({ path, dot, obj, dotPath }:
        el:
        if obj ? "${el}" then
          let
            path' = path ++ [ el ];
            obj' = obj."${el}";
          in if obj' ? "." then {
            path = path';
            obj = obj';
            dot = obj'.".";
            dotPath = path';
          } else {
            path = path';
            obj = obj';
            inherit dot dotPath;
          }
        else {
          inherit path dot dotPath;
          obj = { };
        }) {
          path = [ ];
          dotPath = [ ];
          obj = filter;
          dot = { };
        } filepath;
      rootDot = filter."." or { };
      init = pkgs.lib.init filepath;
    in if init == [ ] then
      checkDot filetype true filepath rootDot
    else if latestDotInfo.dot != { } then
      checkDot filetype (latestDotInfo.dotPath == init)
      (pkgs.lib.drop (builtins.length latestDotInfo.dotPath) filepath)
      latestDotInfo.dot
    else
      checkDot filetype false filepath rootDot;

  # filteringMap:
  # - include as a whole (both dir and file) 2
  # - include files recursively with extension from list 1
  #   - allow exclusion
  # - include files with extension from list 0
  #
  # if trying to include something that is excluded:
  # * remove exclusion if it is full match
  # * error as unimplemented otherwise, to avoid more complex algebra

  filterToPath = pathParams: filterMap:
    builtins.path (pathParams // {
      filter = ps: t:
        # Strip derivation prefix (if present) and split path string to list of components
        let
          ps' = if pkgs.lib.hasPrefix "${builtins.storeDir}/" ps then
            pkgs.lib.tail (pkgs.lib.splitString "/"
              (pkgs.lib.removePrefix "${builtins.storeDir}/" ps))
          else
            pkgs.lib.splitString "/" ps;
        in pkgs.lib.hasAttrByPath ps' filterMap
        || checkAncestors t ps' filterMap;
    });

  commonEnv = { DUNE_PROFILE = "dev"; };
  commonBuildInputs = [ base-libs ] ++ external-libs;
  commonNativeBuildInputs = [ ];

  packageDepsImpl = update: field: pkg:
    builtins.foldl' (acc0: v0:
      builtins.foldl' (acc: v: update acc v."${field}") acc0
      (builtins.attrValues v0)) { }
    (builtins.attrValues allDeps.units."${pkg}");

  packageDeps = packageDepsImpl (a: b: a // b);
  packageDepsMulti = packageDepsImpl pkgs.lib.recursiveUpdate;

  packageDefAny = predicate: pkg:
    builtins.foldl' (acc0: v0:
      builtins.foldl' (acc: v: acc || predicate v) acc0
      (builtins.attrValues v0)) false
    (builtins.attrValues info.packages."${pkg}");
  packageHasTestDefs =
    packageDefAny (v: (v.has_inline_tests or false) || v.type == "test");
  packageHasSrcApp =
    packageDefAny ({ src, ... }: pkgs.lib.hasPrefix "src/app/" src);

  packagesDotGraph = let
    sep = "\n  ";
    nonTransitiveDeps = pkg:
      let
        allDeps = packageDeps "pkgs" pkg;
        transitiveDeps =
          builtins.foldl' (acc: depPkg: acc // packageDeps "pkgs" depPkg) { }
          (builtins.attrNames allDeps);
      in builtins.attrNames
      (builtins.removeAttrs allDeps (builtins.attrNames transitiveDeps));
    escape = builtins.replaceStrings [ "-" ] [ "_" ];
    genEdges = pkg:
      pkgs.lib.concatMapStringsSep sep (dep: "${escape pkg} -> ${escape dep}")
      (nonTransitiveDeps pkg);
  in "digraph packages {\n  "
  + pkgs.lib.concatMapStringsSep sep genEdges (builtins.attrNames allDeps.units)
  + ''

    }'';

  genPatch = self: fileDeps: exeDeps:
    let
      traverseExes = f:
        builtins.concatLists (pkgs.lib.mapAttrsToList (pkg: nameMap:
          builtins.map (name: f pkg name info.packages."${pkg}".exe."${name}")
          (builtins.attrNames nameMap)) exeDeps);
      exes = traverseExes (pkg: key:
        { src, name, ... }:
        let exeDrv = self.all-exes."${pkg}"."${key}";
        in "'${exeDrv}/bin/${key}' '${src}/${name}.exe'");
      # TODO if exe is public, try to promote to package dependency and use as such
      installExes = if exes == [ ] then
        ""
      else ''
        exesArr=( ${builtins.concatStringsSep " " exes} )
        for i in {0..${builtins.toString (builtins.length exes - 1)}}; do
          src="''${exesArr[$i*2]}"
          dst="''${exesArr[$i*2+1]}"
          install -D "$src" "$dst"
        done
      '';
    in {
      fileDeps = builtins.map (dep: self.files."${quote dep}")
        (builtins.attrNames fileDeps);
      patchPhase = ''
        runHook prePatch

        for fileDep in $fileDeps; do
          cp --no-preserve=mode,ownership -RLTu $fileDep ./
        done
        ${installExes}

        runHook postPatch
      '';
    };

  installNixSupport = ''
    mkdir -p $out/nix-support
    {
      echo -n 'export OCAMLPATH=$'
      echo -n '{OCAMLPATH-}$'
      echo '{OCAMLPATH:+:}'"$out/install/default/lib"
      if [[ -d $out/install/default/lib/stublibs ]]; then
        echo -n 'export CAML_LD_LIBRARY_PATH=$'
        echo -n '{CAML_LD_LIBRARY_PATH-}$'
        echo '{CAML_LD_LIBRARY_PATH:+:}'"$out/install/default/lib/stublibs"
      fi
    } > $out/nix-support/setup-hook
    [ ! -d $out/install/default/bin ] || ln -s install/default/bin $out/bin
  '';

  # Make separate libs a separately-built derivation instead of `rm -Rf` hack
  genPackage = self: pkg: pkgDef:
    let
      sepPackages = separatedPackages pkg;
      packageArg = if info.pseudoPackages ? "${pkg}" then
        info.pseudoPackages."${pkg}"
      else
        "@install --only-packages=${pkg}";
    in if sepPackages != [ ] then
      throw "Package ${pkg} has separated lib dependency to packages ${
        builtins.concatStringsSep ", " sepPackages
      }"
    else
      let
        pkgDeps = builtins.filter (d: !(info.pseudoPackages ? "${d}"))
          (builtins.attrNames (packageDeps "pkgs" pkg));
      in pkgs.stdenv.mkDerivation (final:
        {
          pname = pkg;
          version = "dev";
          src = self.src.pkgs."${pkg}";
          dontCheck = true;
          buildInputs = commonBuildInputs
            ++ pkgs.lib.attrVals pkgDeps self.pkgs;
          nativeBuildInputs = commonNativeBuildInputs;
          buildPhase = ''
            runHook preBuild

            dune build \
              ${if final.dontCheck then "" else " @runtest "} \
              ${packageArg} \
              -j $NIX_BUILD_CORES --root=. --build-dir=_build

            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall

            mv _build $out
            ${installNixSupport}

            runHook postInstall
          '';
        } // genPatch self (packageDeps "files" pkg)
        (packageDepsMulti "exes" pkg));

  genTestedPackage = self: pkg: _:
    let
      drv = self.pkgs."${pkg}";
      # For detached units (with no package) there is no need to rely on pre-built
      # libraries/executables because detached units can not be a dependency of other
      # packages, hence no use to introduce indirection
      usePrebuilt = s:
        if info.pseudoPackages ? "${pkg}" then
          { }
        else {
          postPatch = ''
            drv=""
            for input in $nativeBuildInputs; do
              if [[ "$input" ~= '-${pkg}-dev$' ]]; then
                drv="$input"
              fi
            done
            [[ "$drv" == "" ]] && exit 2
            cp --no-preserve=mode,ownership -RL "$drv" _build
          '';
          nativeBuildInputs = s.nativeBuildInputs ++ [ drv ];
        };
    in drv.overrideAttrs (s:
      usePrebuilt s // {
        pname = "test-${pkg}";
        installPhase = "touch $out";
        dontCheck = false;
      });

  genExe = self: pkg: name: exeDef:
    let
      deps = field: allDeps.units."${pkg}".exe."${name}"."${field}" or { };
      pkgDeps = builtins.filter (d: !(info.pseudoPackages ? "${d}"))
        (builtins.attrNames (deps "pkgs"));
    in pkgs.stdenv.mkDerivation ({
      pname = "${name}.exe";
      version = "dev";
      src = self.src.all-exes."${pkg}"."${name}";
      buildInputs = commonBuildInputs ++ pkgs.lib.attrVals pkgDeps self.pkgs;
      nativeBuildInputs = commonNativeBuildInputs;
      buildPhase = ''
        dune build -j $NIX_BUILD_CORES --root=. --build-dir=_build "${exeDef.src}/${exeDef.name}.exe"
      '';
      installPhase = ''
        mkdir -p $out/bin
        mv "_build/default/${exeDef.src}/${exeDef.name}.exe" $out/bin/${name}
      '';
    } // genPatch self (deps "files") (deps "exes"));

  genFile = self: pname: src:
    let deps = field: allDeps.files."${src}"."${field}";
    in pkgs.stdenv.mkDerivation ({
      inherit pname;
      version = "dev";
      src = self.src.files."${pname}";
      buildInputs = commonBuildInputs;
      nativeBuildInputs = commonNativeBuildInputs;
      buildPhase = ''
        dune build ${
          builtins.concatStringsSep " "
          (builtins.attrNames info.srcInfo."${src}".file_outs)
        }
      '';
      installPhase = ''
        rm -Rf _build/default/.dune
        mv _build/default $out
      '';
    } // genPatch self (deps "files") (deps "exes"));

  duneAndFileDepsFilters = src:
    let
      duneFile = if src == "." then "dune" else "${src}/dune";
      notAnOutput = dep:
        !(info.fileOuts2Src ? "${dep}" || info.exes ? "${dep}");
      srcFiles = [ duneFile ] ++ builtins.attrNames
        info.srcInfo."${src}".file_outs
        # ^ include out files is they exist in file system so that dune can handle mode correctly
        ++ builtins.filter notAnOutput info.srcInfo."${src}".file_deps;
    in builtins.map (mkFilter dotIncludeAll) srcFiles;

  unitFilters = src: duneSubdirs: includeSubdirs:
    { with_standard, include, exclude }:
    let
      srcPrefix = if src == "." then "" else "${src}/";
      mapModuleFiles = f: a:
        builtins.map (mkFilter dotIncludeAll) [
          "${srcPrefix}${a}.ml"
          "${srcPrefix}${a}.mli"
        ];
      srcParts = if src == "." then [ ] else pkgs.lib.splitString "/" src;
      exclude' =
        # Commented out because although dune doesn't need the module,
        # it still wants it to be present in filesystem
        # builtins.concatMap (a: [ [ "${a}.ml" ] [ "${a}.mli" ] ]) exclude ++
        builtins.map (pkgs.lib.splitString "/") duneSubdirs;
    in builtins.concatMap (mapModuleFiles (mkFilter dotIncludeAll)) include
    ++ (if with_standard then
      [
        (mkFilter {
          type = if includeSubdirs then 1 else 0;
          ext = [ "ml" "mli" ];
          exclude = exclude';
        } src)
      ]
    else
      [ ]);

  unitSourceFilters = { src, ... }@unit:
    duneAndFileDepsFilters src
    ++ unitFilters src (info.srcInfo."${src}".subdirs or [ ])
    ((info.srcInfo."${src}".include_subdirs or "no") != "no") ({
      with_standard = true;
      include = [ ];
      exclude = [ ];
    } // (unit.modules or { }));

  unitSourceFiltersWithExtra = extraLibs: unit:
    let
      extraUnits = builtins.concatLists (pkgs.lib.mapAttrsToList
        (pkg: libs: pkgs.lib.attrVals libs info.packages."${pkg}".lib)
        extraLibs);
    in builtins.concatMap unitSourceFilters ([ unit ] ++ extraUnits);

  separatedPackages = pkg:
    builtins.attrNames (attrFold (acc0: type:
      attrFold (acc1: name: _:
        acc1 // (separatedLibs."${pkg}"."${type}"."${name}" or { })) acc0) { }
      info.packages."${pkg}");

  # Only sources, without dependencies built by other derivations
  genPackageSrc = pkg: pkgDef:
    let
      pseudoPkgDeps = builtins.filter (d: info.pseudoPackages ? "${d}")
        (builtins.attrNames (packageDeps "pkgs" pkg));
      sepLibs = builtins.mapAttrs (_: { lib, ... }: builtins.attrNames lib)
        (pkgs.lib.getAttrs pseudoPkgDeps info.packages);
      filters = builtins.concatLists (builtins.concatLists
        (pkgs.lib.mapAttrsToList
          (_: pkgs.lib.mapAttrsToList (_: unitSourceFiltersWithExtra sepLibs))
          pkgDef));
    in filterToPath {
      path = ./..;
      name = "source-${pkg}";
    } (mergeFilters filters);
  genExeSrc = pkg: name: exeDef:
    let
      deps = field: allDeps.units."${pkg}".exe."${name}"."${field}" or { };
      pseudoPkgDeps = builtins.filter (d: info.pseudoPackages ? "${d}")
        (builtins.attrNames (deps "pkgs"));
      sepLibs = builtins.mapAttrs (_: builtins.attrNames) ((deps "libs")
        // builtins.mapAttrs (_: { lib, ... }: lib)
        (pkgs.lib.getAttrs pseudoPkgDeps info.packages));
    in filterToPath {
      path = ./..;
      name = "source-${name}-exe";
    } (mergeFilters (unitSourceFiltersWithExtra sepLibs exeDef));
  genFileSrc = name: src:
    filterToPath {
      path = ./..;
      inherit name;
    } (mergeFilters (duneAndFileDepsFilters src));

  mkOutputs = genPackage: genTestedPackage: genExe: genFile: {
    pkgs = builtins.mapAttrs genPackage info.packages;
    tested = builtins.mapAttrs genTestedPackage info.packages;
    all-exes =
      builtins.mapAttrs (pkg: { exe, ... }: builtins.mapAttrs (genExe pkg) exe)
      (pkgs.lib.filterAttrs (_: v: v ? "exe") info.packages);
    files = pkgs.lib.mapAttrs' (k: _:
      let name = quote k;
      in {
        inherit name;
        value = genFile name k;
      }) allDeps.files;
  };

  mkCombined = name: buildInputs:
    pkgs.stdenv.mkDerivation {
      inherit name buildInputs;
      phases = [ "buildPhase" "installPhase" ];
      buildPhase = ''
        echo "Build inputs: $buildInputs"
      '';
      installPhase = ''
        touch $out
      '';
    };

  customTest = super: pkg:
    let src = info.pseudoPackages."${pkg}";
    in super.pkgs."${pkg}".overrideAttrs {
      pname = "test-${pkg}";
      installPhase = "touch $out";
      dontCheck = false;
      buildPhase = ''
        runHook preBuild
        cp ${../${src}/Makefile} ${src}/Makefile
        make -C ${src} VERBOSE=1
        runHook postBuild
      '';
    };

  canonicalizePath = ps:
    let
      p = pkgs.lib.splitString "/" ps;
      p' = builtins.foldl' (acc: el:
        if el == "." then
          acc
        else if acc == [ ] then
          [ el ]
        else if el == ".." && pkgs.lib.last acc != ".." then
          pkgs.lib.init acc
        else
          acc ++ [ el ]) [ ] p;
    in pkgs.lib.concatStringsSep "/" p';
  fixupSymlinksInSource = pkgName: src: root:
    let
      depListDrv = pkgs.stdenv.mkDerivation {
        inherit src;
        name = "${pkgName}-symlink-targets";
        phases = [ "unpackPhase" "installPhase" ];
        installPhase = ''
          find -type l -exec bash -c 'echo "$(dirname {})/$(readlink {})"' ';' > $out
          find \( -type f -o -type l \) >> $out
        '';
      };
      fileListTxt = builtins.readFile depListDrv;
      fileList =
        builtins.map canonicalizePath (pkgs.lib.splitString "\n" fileListTxt);
      filters = builtins.map (mkFilter dotIncludeAll) fileList;
    in filterToPath {
      path = root;
      name = "source-${pkgName}-with-correct-symlinks";
    } (mergeFilters filters);

  vmTestBuildInputs = self: pkgNames:
    builtins.concatMap (pkg:
      let drv = self.pkgs."${pkg}";
      in drv.buildInputs ++ drv.nativeBuildInputs) pkgNames;

  vmTestScript = self: name: auxBuildInputs: pkgNames: testTargetString:
    let
      copyPkg = pkg:
        "cp --no-preserve=mode,ownership,timestamps -RLTu ${
          self.src.pkgs."${pkg}"
        } .";
      copyPrebuilt = pkg:
        "cp --no-preserve=mode,ownership,timestamps -RLTu ${
          self.pkgs."${pkg}"
        } _build";
      buildInputs = vmTestBuildInputs self pkgNames ++ auxBuildInputs;
      subpaths = suffix:
        builtins.filter builtins.pathExists
        (builtins.map (drv: "${drv.out}/${suffix}") buildInputs);
      libs = subpaths "lib";
      bins = subpaths "bin";
      setupHooks = subpaths "nix-support/setup-hook";
      propagatedFiles = subpaths "nix-support/propagated-build-inputs";
      propagatedScript = if propagatedFiles == [ ] then
        ""
      else ''
        filesToProcess=${builtins.concatStringsSep " " propagatedFiles}
        while [[ "$filesToProcess" != "" ]]; do
          next=""
          for pbiFile in $filesToProcess; do
            for input in $(<$pbiFile); do
              [ ! -d "$input/lib" ] || export LIBRARY_PATH="''${LIBRARY_PATH:+$LIBRARY_PATH:}$input/lib"
              [ ! -d "$input/bin" ] || export PATH="''${PATH:+$PATH:}$input/bin"
              if [[ -f "$input/nix-support/propagated-build-inputs" ]]; then
                next="$next $input/nix-support/propagated-build-inputs"
              fi
            done
          done
          filesToProcess="$next"
        done
      '';
    in pkgs.writeShellScriptBin "runtest-${name}" ''
      ${pkgs.lib.concatMapStringsSep "\n" (hook: "source " + hook) setupHooks}
      export LIBRARY_PATH="''${LIBRARY_PATH:+$LIBRARY_PATH:}${
        builtins.concatStringsSep ":" libs
      }"
      export PATH="''${PATH:+$PATH:}${builtins.concatStringsSep ":" bins}"
      ${propagatedScript}
      ${pkgs.lib.concatMapStringsSep "\n" copyPkg pkgNames}
      ${pkgs.lib.concatMapStringsSep "\n" copyPrebuilt pkgNames}
      dune build ${testTargetString} -j 8 --root=. --build-dir=_build
    '';

  vmTest = self: name: auxPackages: pkgNames: testTargetString:
    let vmScript = vmTestScript self name [ ] pkgNames testTargetString;
    in mkVmTest ([ vmScript ] ++ auxPackages ++ vmTestBuildInputs self pkgNames)
    name;

  mkVmTest = packages: name:
    pkgs.testers.runNixOSTest {
      name = "vmtest-${name}";
      nodes.machine = { config, pkgs, ... }: {
        security.pam.loginLimits = [{
          domain = "*";
          type = "soft";
          item = "nofile";
          value = "65536";
        }];
        users.users.mina = {
          isNormalUser = true;
          home = "/home/mina";
          extraGroups = [ "wheel" ];
          inherit packages;
        };
        system.stateVersion = "23.11";
        virtualisation = {
          graphics = false;
          cores = 8;
          memorySize = 16384; # TODO Lower the requirement
          diskSize = 4096;
        };
      };
      testScript = ''
        machine.wait_for_unit("default.target")
        machine.succeed("cd /home/mina && su -- mina -c 'runtest-${name}'")
      '';
    };

  nonConsensusPkgs = builtins.filter (s:
    pkgs.lib.hasSuffix "_nonconsensus" s
    || pkgs.lib.hasPrefix "__src-nonconsensus-" s)
    (builtins.attrNames info.packages);
  nonConsensusSrcOverrides = super:
    pkgs.lib.genAttrs nonConsensusPkgs
    (pkg: fixupSymlinksInSource pkg super."${pkg}" ../.);

  sqlSchemaFiles = with inputs.nix-filter.lib;
    filter {
      root = ../src/app/archive;
      include = [ (matchExt "sql") ];
    };

  skippedTest = pkgs.stdenv.mkDerivation {
    name = "skipped-test";
    phases = [ "installPhase" ];
    installPhase = ''
      echo "echo test is skipped" > $out
    '';
  };

  testOrPkgImpl = noTest: self: pkg:
    let
      hasTestDefs = !noTest && packageHasTestDefs pkg;
      isPseudo = info.pseudoPackages ? "${pkg}";
    in if hasTestDefs && isPseudo then
      [ self.tested."${pkg}" ]
    else if hasTestDefs && !isPseudo then [
      self.pkgs."${pkg}"
      self.tested."${pkg}"
    ] else
      [ self.pkgs."${pkg}" ];
  testOrPkg = testOrPkgImpl false;
  testOrPkg' = self: pkg: testOrPkgImpl (packageHasSrcApp pkg) self pkg;

  packageNames = builtins.attrNames info.packages;

  minaPkgs = self:
    let
      super0 = mkOutputs (genPackage self) (genTestedPackage self) (genExe self)
        (genFile self) // {
          src = mkOutputs genPackageSrc genPackageSrc genExeSrc genFileSrc;
          exes = builtins.foldl' (acc:
            { package, name }:
            # TODO for exes within packages, use package derivation
            acc // {
              "${name}" = if acc ? "${name}" then
                throw "Executable with name ${name} defined more than once"
              else
                self.all-exes."${package}"."${name}";
            }) { } (builtins.attrValues info.exes) // {
              libp2p_helper = pkgs.libp2p_helper;
            };
          all = mkCombined "all"
            (builtins.map (pkg: self.pkgs."${pkg}") packageNames);
          default = mkCombined "default"
            (builtins.concatMap (testOrPkg' self) packageNames);
          all-tested = mkCombined "all-tested"
            (builtins.concatMap (testOrPkg self) packageNames);
        };
      super = pkgs.lib.recursiveUpdate super0 {
        src.pkgs = nonConsensusSrcOverrides super0.src.pkgs;
      };
      marlinPlonkStubs = {
        MARLIN_PLONK_STUBS = "${pkgs.kimchi_bindings_stubs}";
      };
      childProcessesTester = pkgs.writeShellScriptBin "mina-tester.sh"
        (builtins.readFile ../src/lib/child_processes/tester.sh);
      withLibp2pHelper = (s: {
        nativeBuildInputs = s.nativeBuildInputs ++ [ pkgs.libp2p_helper ];
      });
    in pkgs.lib.recursiveUpdate super {
      pkgs.mina_version_compiled =
        super.pkgs.mina_version_compiled.overrideAttrs {
          MINA_COMMIT_SHA1 = inputs.self.sourceInfo.rev or "<dirty>";
        };
      pkgs.kimchi_bindings =
        super.pkgs.kimchi_bindings.overrideAttrs marlinPlonkStubs;
      pkgs.kimchi_types =
        super.pkgs.kimchi_types.overrideAttrs marlinPlonkStubs;
      pkgs.pasta_bindings =
        super.pkgs.pasta_bindings.overrideAttrs marlinPlonkStubs;
      pkgs.libp2p_ipc = super.pkgs.libp2p_ipc.overrideAttrs (s: {
        GO_CAPNP_STD = "${pkgs.go-capnproto2.src}/std";
        nativeBuildInputs = s.nativeBuildInputs ++ [ pkgs.capnproto ];
      });
      pkgs.bindings_js = super.pkgs.bindings_js.overrideAttrs {
        PLONK_WASM_NODEJS = "${pkgs.plonk_wasm}/nodejs";
        PLONK_WASM_WEB = "${pkgs.plonk_wasm}/web";
      };
      files.src-lib-crypto-kimchi_bindings-js-node_js =
        super.files.src-lib-crypto-kimchi_bindings-js-node_js.overrideAttrs {
          PLONK_WASM_NODEJS = "${pkgs.plonk_wasm}/nodejs";
        };
      files.src-lib-crypto-kimchi_bindings-js-web =
        super.files.src-lib-crypto-kimchi_bindings-js-web.overrideAttrs {
          PLONK_WASM_WEB = "${pkgs.plonk_wasm}/web";
        };
      pkgs.__src-lib-ppx_mina-tests__ =
        customTest super "__src-lib-ppx_mina-tests__";
      pkgs.__src-lib-ppx_version-test__ =
        customTest super "__src-lib-ppx_version-test__";
      tested.child_processes = super.tested.child_processes.overrideAttrs
        (s: { buildInputs = s.buildInputs ++ [ childProcessesTester ]; });
      tested.block_storage =
        super.tested.block_storage.overrideAttrs withLibp2pHelper;
      tested.mina_lib = super.tested.mina_lib.overrideAttrs withLibp2pHelper;
      tested.mina_lib_tests =
        super.tested.mina_lib_tests.overrideAttrs withLibp2pHelper;
      tested.archive_lib = super.tested.archive_lib.overrideAttrs (s: {
        buildInputs = s.buildInputs ++ [ pkgs.ephemeralpg ];
        preBuild = ''
          export MINA_TEST_POSTGRES="$(pg_tmp -w 1200)"
          ( cd ${sqlSchemaFiles} && psql "$MINA_TEST_POSTGRES" < create_schema.sql >/dev/null )
        '';
      });
      # TODO remove this override after merging the latest `develop`
      tested.__src-lib-crypto-snarky_tests__ = skippedTest;
      tested.__src-test-command_line_tests__ =
        vmTest self "cmd-tests" [ pkgs.libp2p_helper ]
        [ "__src-test-command_line_tests__" ] "src/test/command_line_tests";
      tested.__src-lib-staged_ledger-test__ =
        vmTest self "staged-ledger-tests" [ ]
        [ "__src-lib-staged_ledger-test__" ] "src/lib/staged_ledger/test";
      tested.__src-lib-mina_net2-tests__ = skippedTest;
      tested.mina_net2 =
        vmTest self "mina_net2-tests" [ pkgs.libp2p_helper pkgs.gcc ] [
          "mina_net2"
          "__src-lib-mina_net2-tests__"
        ] "src/lib/mina_net2";
    };

  overlay = self: super:
    let
      ocaml-libs = builtins.attrValues (getAttrs installedPackageNames self);

      # Make a script wrapper around a binary, setting all the necessary environment variables and adding necessary tools to PATH.
      # Also passes the version information to the executable.
      wrapMina = let commit_sha1 = inputs.self.sourceInfo.rev or "<dirty>";
      in package:
      { deps ? [ pkgs.gnutar pkgs.gzip ] }:
      pkgs.runCommand "${package.name}-release" {
        buildInputs = [ pkgs.makeBinaryWrapper pkgs.xorg.lndir ];
        outputs = package.outputs;
      } (map (output: ''
        mkdir -p ${placeholder output}
        lndir -silent ${package.${output}} ${placeholder output}
        for i in $(find -L "${placeholder output}/bin" -type f); do
          wrapProgram "$i" \
            --prefix PATH : ${makeBinPath deps} \
            --set MINA_LIBP2P_HELPER_PATH ${pkgs.libp2p_helper}/bin/mina-libp2p_helper \
            --set MINA_COMMIT_SHA1 ${escapeShellArg commit_sha1}
        done
      '') package.outputs);

      # Derivation which has all Mina's dependencies in it, and creates an empty output if the command succeds.
      # Useful for unit tests.
      runMinaCheck = { name ? "check", extraInputs ? [ ], extraArgs ? { }, }:
        check:
        self.mina-dev.overrideAttrs (oa:
          {
            pname = "mina-${name}";
            buildInputs = oa.buildInputs ++ extraInputs;
            buildPhase = check;
            outputs = [ "out" ];
            installPhase = "touch $out";
          } // extraArgs);
    in {
      # Some "core" Mina executables, without the version info.
      mina-dev = pkgs.stdenv.mkDerivation ({
        pname = "mina";
        version = "dev";
        # Only get the ocaml stuff, to reduce the amount of unnecessary rebuilds
        src = with inputs.nix-filter.lib;
          filter {
            root = ./..;
            include = [
              (inDirectory "src")
              "dune"
              "dune-project"
              "./graphql_schema.json"
              "opam.export"
            ];
          };

        withFakeOpam = false;

        # TODO, get this from somewhere
        MARLIN_REPO_SHA = "<unknown>";
        MINA_COMMIT_SHA1 = "<unknown>";
        MINA_COMMIT_DATE = "<unknown>";
        MINA_BRANCH = "<unknown>";

        DUNE_PROFILE = "dev";

        NIX_LDFLAGS =
          optionalString (pkgs.stdenv.isDarwin && pkgs.stdenv.isAarch64)
          "-F${pkgs.darwin.apple_sdk.frameworks.CoreFoundation}/Library/Frameworks -framework CoreFoundation";

        buildInputs = ocaml-libs ++ external-libs;

        nativeBuildInputs = [
          self.dune
          self.ocamlfind
          self.odoc
          self.lld_wrapped
          pkgs.capnproto
          pkgs.removeReferencesTo
          pkgs.fd
        ] ++ ocaml-libs;

        # todo: slimmed rocksdb
        MINA_ROCKSDB = "${pkgs.rocksdb-mina}/lib/librocksdb.a";
        GO_CAPNP_STD = "${pkgs.go-capnproto2.src}/std";

        # this is used to retrieve the path of the built static library
        # and copy it from within a dune rule
        # (see src/lib/crypto/kimchi_bindings/stubs/dune)
        MARLIN_PLONK_STUBS = "${pkgs.kimchi_bindings_stubs}";
        DISABLE_CHECK_OPAM_SWITCH = "true";

        MINA_VERSION_IMPLEMENTATION = "mina_version.runtime";

        PLONK_WASM_NODEJS = "${pkgs.plonk_wasm}/nodejs";
        PLONK_WASM_WEB = "${pkgs.plonk_wasm}/web";

        configurePhase = ''
          export MINA_ROOT="$PWD"
          export -f patchShebangs isScript
          fd . --type executable -x bash -c "patchShebangs {}"
          export -n patchShebangs isScript
          # Get the mina version at runtime, from the wrapper script. Used to prevent rebuilding everything every time commit info changes.
          sed -i "s/mina_version_compiled/mina_version.runtime/g" src/app/cli/src/dune src/app/rosetta/dune src/app/archive/dune
        '';

        buildPhase = ''
          dune build --display=short \
            src/app/logproc/logproc.exe \
            src/app/cli/src/mina.exe \
            src/app/batch_txn_tool/batch_txn_tool.exe \
            src/app/cli/src/mina_testnet_signatures.exe \
            src/app/cli/src/mina_mainnet_signatures.exe \
            src/app/rosetta/rosetta.exe \
            src/app/rosetta/rosetta_testnet_signatures.exe \
            src/app/rosetta/rosetta_mainnet_signatures.exe \
            src/app/generate_keypair/generate_keypair.exe \
            src/app/archive/archive.exe \
            src/app/archive_blocks/archive_blocks.exe \
            src/app/extract_blocks/extract_blocks.exe \
            src/app/missing_blocks_auditor/missing_blocks_auditor.exe \
            src/app/replayer/replayer.exe \
            src/app/swap_bad_balances/swap_bad_balances.exe \
            src/app/runtime_genesis_ledger/runtime_genesis_ledger.exe \
            src/app/berkeley_migration/berkeley_migration.exe \
            src/app/berkeley_migration_verifier/berkeley_migration_verifier.exe
          # TODO figure out purpose of the line below
          # dune exec src/app/runtime_genesis_ledger/runtime_genesis_ledger.exe -- --genesis-dir _build/coda_cache_dir
          # Building documentation fails, because not everything in the source tree compiles. Ignore the errors.
          dune build @doc || true
        '';

        outputs = [
          "out"
          "archive"
          "generate_keypair"
          "mainnet"
          "testnet"
          "genesis"
          "sample"
          "batch_txn_tool"
          "berkeley_migration"
        ];

        installPhase = ''
          mkdir -p $out/bin $archive/bin $sample/share/mina $out/share/doc $generate_keypair/bin $mainnet/bin $testnet/bin $genesis/bin $genesis/var/lib/coda $batch_txn_tool/bin $berkeley_migration/bin
          # TODO uncomment when genesis is generated above
          # mv _build/coda_cache_dir/genesis* $genesis/var/lib/coda
          pushd _build/default
          cp src/app/cli/src/mina.exe $out/bin/mina
          cp src/app/logproc/logproc.exe $out/bin/logproc
          cp src/app/rosetta/rosetta.exe $out/bin/rosetta
          cp src/app/batch_txn_tool/batch_txn_tool.exe $batch_txn_tool/bin/batch_txn_tool
          cp src/app/runtime_genesis_ledger/runtime_genesis_ledger.exe $genesis/bin/runtime_genesis_ledger
          cp src/app/runtime_genesis_ledger/runtime_genesis_ledger.exe $out/bin/runtime_genesis_ledger
          cp src/app/cli/src/mina_mainnet_signatures.exe $mainnet/bin/mina_mainnet_signatures
          cp src/app/rosetta/rosetta_mainnet_signatures.exe $mainnet/bin/rosetta_mainnet_signatures
          cp src/app/cli/src/mina_testnet_signatures.exe $testnet/bin/mina_testnet_signatures
          cp src/app/rosetta/rosetta_testnet_signatures.exe $testnet/bin/rosetta_testnet_signatures
          cp src/app/generate_keypair/generate_keypair.exe $generate_keypair/bin/generate_keypair
          cp src/app/archive/archive.exe $archive/bin/mina-archive
          cp src/app/archive_blocks/archive_blocks.exe $archive/bin/mina-archive-blocks
          cp src/app/missing_blocks_auditor/missing_blocks_auditor.exe $archive/bin/mina-missing-blocks-auditor
          cp src/app/replayer/replayer.exe $archive/bin/mina-replayer
          cp src/app/replayer/replayer.exe $berkeley_migration/bin/mina-migration-replayer
          cp src/app/berkeley_migration/berkeley_migration.exe $berkeley_migration/bin/mina-berkeley-migration
          cp src/app/berkeley_migration_verifier/berkeley_migration_verifier.exe $berkeley_migration/bin/mina-berkeley-migration-verifier
          cp src/app/swap_bad_balances/swap_bad_balances.exe $archive/bin/mina-swap-bad-balances
          cp -R _doc/_html $out/share/doc/html
          # cp src/lib/mina_base/sample_keypairs.json $sample/share/mina
          popd
          remove-references-to -t $(dirname $(dirname $(command -v ocaml))) {$out/bin/*,$mainnet/bin/*,$testnet/bin*,$genesis/bin/*,$generate_keypair/bin/*}
        '';
        shellHook =
          "export MINA_LIBP2P_HELPER_PATH=${pkgs.libp2p_helper}/bin/mina-libp2p_helper";
      } // optionalAttrs pkgs.stdenv.isDarwin {
        OCAMLPARAM = "_,cclib=-lc++";
      });

      # Same as above, but wrapped with version info.
      mina = wrapMina self.mina-dev { };

      # Mina with additional instrumentation info.
      with-instrumentation-dev = self.mina-dev.overrideAttrs (oa: {
        pname = "with-instrumentation";
        outputs = [ "out" ];

        buildPhase = ''
          dune build  --display=short --profile=testnet_postake_medium_curves --instrument-with bisect_ppx src/app/cli/src/mina.exe
        '';
        installPhase = ''
          mkdir -p $out/bin
          mv _build/default/src/app/cli/src/mina.exe $out/bin/mina
        '';
      });

      with-instrumentation = wrapMina self.with-instrumentation-dev { };

      mainnet-pkg = self.mina-dev.overrideAttrs (s: {
        version = "mainnet";
        DUNE_PROFILE = "mainnet";
        # For compatibility with Docker build
        MINA_ROCKSDB = "${pkgs.rocksdb-mina}/lib/librocksdb.a";
      });

      mainnet = wrapMina self.mainnet-pkg { };

      devnet-pkg = self.mina-dev.overrideAttrs (s: {
        version = "devnet";
        DUNE_PROFILE = "devnet";
        # For compatibility with Docker build
        MINA_ROCKSDB = "${pkgs.rocksdb-mina}/lib/librocksdb.a";
      });

      devnet = wrapMina self.devnet-pkg { };

      # Unit tests
      mina_tests = runMinaCheck {
        name = "tests";
        extraArgs = {
          MINA_LIBP2P_HELPER_PATH =
            "${pkgs.libp2p_helper}/bin/mina-libp2p_helper";
          MINA_LIBP2P_PASS = "naughty blue worm";
          MINA_PRIVKEY_PASS = "naughty blue worm";
          TZDIR = "${pkgs.tzdata}/share/zoneinfo";
        };
        extraInputs = [ pkgs.ephemeralpg ];
      } ''
        dune build graphql_schema.json --display=short
        export MINA_TEST_POSTGRES="$(pg_tmp -w 1200)"
        pushd src/app/archive
        psql "$MINA_TEST_POSTGRES" < create_schema.sql
        popd
        # TODO: investigate failing tests, ideally we should run all tests in src/
        dune runtest src/app/archive src/lib/command_line_tests --display=short
      '';

      # Check if the code is formatted properly
      mina-ocaml-format = runMinaCheck { name = "ocaml-format"; } ''
        dune exec --profile=dev src/app/reformat/reformat.exe -- -path . -check
      '';

      # Integration test executive
      test_executive-dev = self.mina-dev.overrideAttrs (oa: {
        pname = "mina-test_executive";
        outputs = [ "out" ];

        buildPhase = ''
          dune build --profile=integration_tests src/app/test_executive/test_executive.exe src/app/logproc/logproc.exe -j$NIX_BUILD_CORES
        '';
        installPhase = ''
          mkdir -p $out/bin
          mv _build/default/src/app/test_executive/test_executive.exe $out/bin/test_executive
          mv _build/default/src/app/logproc/logproc.exe $out/bin/logproc
        '';
      });

      test_executive = wrapMina self.test_executive-dev { };

      experiment = minaPkgs self.experiment // {
        inherit dune-description;
        src-info =
          pkgs.writeText "src-info.json" (builtins.toJSON info.srcInfo);
        exe-info = pkgs.writeText "exes.json" (builtins.toJSON info.exes);
        packages =
          pkgs.writeText "packages.json" (builtins.toJSON info.packages);
        separated-libs =
          pkgs.writeText "separated-libs.json" (builtins.toJSON separatedLibs);
        all-deps = pkgs.writeText "all-deps.json" (allDepsToJSON allDeps);
        package-deps-graph = pkgs.writeText "packages.dot" packagesDotGraph;
        inherit base-libs;
      };

    };
in scope.overrideScope' overlay
