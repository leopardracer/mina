let Cmd = ../../Lib/Cmds.dhall

let S = ../../Lib/SelectFiles.dhall

let Pipeline = ../../Pipeline/Dsl.dhall

let PipelineTag = ../../Pipeline/Tag.dhall

let JobSpec = ../../Pipeline/JobSpec.dhall

let Command = ../../Command/Base.dhall

let RunInToolchain = ../../Command/RunInToolchain.dhall

let Docker = ../../Command/Docker/Type.dhall

let Size = ../../Command/Size.dhall

let DebianVersions = ../../Constants/DebianVersions.dhall

let Network = ../../Constants/Network.dhall

let Profiles = ../../Constants/Profiles.dhall

let dependsOn =
      DebianVersions.dependsOn
        DebianVersions.DebVersion.Bullseye
        Network.Type.Devnet
        Profiles.Type.Standard

let buildTestCmd
    : Text -> Size -> List Command.TaggedKey.Type -> Command.Type
    =     \(release_branch : Text)
      ->  \(cmd_target : Size)
      ->  \(dependsOn : List Command.TaggedKey.Type)
      ->  Command.build
            Command.Config::{
            , commands =
                  RunInToolchain.runInToolchain
                    ([] : List Text)
                    "buildkite/scripts/dump-mina-type-shapes.sh"
                # [ Cmd.run
                      "gsutil cp \$(git log -n 1 --format=%h --abbrev=7 --no-merges)-type_shape.txt \$MINA_TYPE_SHAPE gs://mina-type-shapes"
                  ]
                # RunInToolchain.runInToolchain
                    ([] : List Text)
                    "buildkite/scripts/version-linter.sh ${release_branch}"
            , label = "Lint: Version Type Shapes"
            , key = "version-linter"
            , target = cmd_target
            , docker = None Docker.Type
            , depends_on = dependsOn
            , artifact_paths = [ S.contains "core_dumps/*" ]
            }

in  Pipeline.build
      Pipeline.Config::{
      , spec =
          let lintDirtyWhen =
                [ S.strictlyStart (S.contains "src")
                , S.exactly "buildkite/src/Jobs/Test/VersionLint" "dhall"
                , S.exactly "buildkite/scripts/version-linter" "sh"
                ]

          in  JobSpec::{
              , dirtyWhen = lintDirtyWhen
              , path = "Test"
              , name = "VersionLint"
              , tags =
                [ PipelineTag.Type.Long
                , PipelineTag.Type.Test
                , PipelineTag.Type.Stable
                ]
              }
      , steps = [ buildTestCmd "develop" Size.Small dependsOn ]
      }
