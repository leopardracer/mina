open Core_kernel

module Tree = struct
  [%%versioned
  module Stable = struct
    [@@@no_toplevel_latest_type]

    module V1 = struct
      type ('hash, 'account) t =
        | Account of 'account
        | Hash of 'hash
        | Node of 'hash * ('hash, 'account) t * ('hash, 'account) t
      [@@deriving equal, sexp, yojson]

      let rec to_latest acct_to_latest = function
        | Account acct ->
            Account (acct_to_latest acct)
        | Hash hash ->
            Hash hash
        | Node (hash, l, r) ->
            Node (hash, to_latest acct_to_latest l, to_latest acct_to_latest r)
    end
  end]

  type ('hash, 'account) t = ('hash, 'account) Stable.Latest.t =
    | Account of 'account
    | Hash of 'hash
    | Node of 'hash * ('hash, 'account) t * ('hash, 'account) t
  [@@deriving equal, sexp, yojson]
end

module T = struct
  [%%versioned
  module Stable = struct
    [@@@no_toplevel_latest_type]

    module V2 = struct
      type ('hash, 'key, 'account) t =
        { indexes : ('key * int) list
        ; depth : int
        ; tree : ('hash, 'account) Tree.Stable.V1.t
        ; current_location : int option
        }
      [@@deriving sexp, yojson]
    end
  end]

  type ('hash, 'key, 'account) t = ('hash, 'key, 'account) Stable.Latest.t =
    { indexes : ('key * int) list
    ; depth : int
    ; tree : ('hash, 'account) Tree.t
    ; current_location : int option
    }
  [@@deriving sexp, yojson]
end

module type S = sig
  type hash

  type account_id

  type account

  type t = (hash, account_id, account) T.t [@@deriving sexp, yojson]

  val of_hash : depth:int -> current_location:int option -> hash -> t

  val allocate_index : t -> account_id -> int * t

  val get_exn : t -> int -> account

  val path_exn : t -> int -> [ `Left of hash | `Right of hash ] list

  val set_exn : t -> int -> account -> t

  val find_index : t -> account_id -> int option

  val add_path :
    t -> [ `Left of hash | `Right of hash ] list -> account_id -> account -> t

  val iteri : t -> f:(int -> account -> unit) -> unit

  val merkle_root : t -> hash

  val depth : t -> int
end

let tree { T.tree; _ } = tree

let of_hash ~depth ~current_location h =
  { T.indexes = []; depth; tree = Hash h; current_location }

module Make (Hash : sig
  type t [@@deriving equal, sexp, yojson, compare]

  val merge : height:int -> t -> t -> t
end) (Account_id : sig
  type t [@@deriving equal, sexp, yojson]
end) (Account : sig
  type t [@@deriving equal, sexp, yojson]

  val data_hash : t -> Hash.t

  val empty : t Lazy.t
end) : sig
  include
    S
      with type hash := Hash.t
       and type account_id := Account_id.t
       and type account := Account.t

  val hash : (Hash.t, Account.t) Tree.t -> Hash.t
end = struct
  let empty_hash =
    lazy
      (Empty_hashes.extensible_cache
         (module Hash)
         ~init_hash:(Account.data_hash (Lazy.force Account.empty)) )

  let empty_hash i = (Lazy.force empty_hash) i

  type t = (Hash.t, Account_id.t, Account.t) T.t [@@deriving sexp, yojson]

  let of_hash ~depth ~current_location (hash : Hash.t) =
    of_hash ~depth ~current_location hash

  let hash : (Hash.t, Account.t) Tree.t -> Hash.t = function
    | Account a ->
        Account.data_hash a
    | Hash h ->
        h
    | Node (h, _, _) ->
        h

  type index = int [@@deriving sexp, yojson]

  let depth { T.depth; _ } = depth

  let merkle_root { T.tree; _ } = hash tree

  let add_path depth0 tree0 path0 account =
    let rec build_tree height p =
      match p with
      | `Left h_r :: path ->
          let l = build_tree (height - 1) path in
          Tree.Node (Hash.merge ~height (hash l) h_r, l, Hash h_r)
      | `Right h_l :: path ->
          let r = build_tree (height - 1) path in
          Node (Hash.merge ~height h_l (hash r), Hash h_l, r)
      | [] ->
          assert (height = -1) ;
          Account account
    in
    let rec union height tree path =
      match (tree, path) with
      | Tree.Hash h, path ->
          let t = build_tree height path in
          [%test_result: Hash.t]
            ~message:
              "Hashes in union are not equal, something is wrong with your \
               ledger"
            ~expect:h (hash t) ;
          t
      | Node (h, l, r), `Left h_r :: path ->
          assert (Hash.equal h_r (hash r)) ;
          let l = union (height - 1) l path in
          Node (h, l, r)
      | Node (h, l, r), `Right h_l :: path ->
          assert (Hash.equal h_l (hash l)) ;
          let r = union (height - 1) r path in
          Node (h, l, r)
      | Node _, [] ->
          failwith "Path too short"
      | Account _, _ :: _ ->
          failwith "Path too long"
      | Account a, [] ->
          assert (Account.equal a account) ;
          tree
    in
    union (depth0 - 1) tree0 (List.rev path0)

  let add_path (t : t) path account_id account =
    let index =
      List.foldi path ~init:0 ~f:(fun i acc x ->
          match x with `Right _ -> acc + (1 lsl i) | `Left _ -> acc )
    in
    { t with
      tree = add_path t.depth t.tree path account
    ; indexes = (account_id, index) :: t.indexes
    }

  let iteri (t : t) ~f =
    let rec go acc i tree ~f =
      match tree with
      | Tree.Account a ->
          f acc a
      | Hash _ ->
          ()
      | Node (_, l, r) ->
          go acc (i - 1) l ~f ;
          go (acc + (1 lsl i)) (i - 1) r ~f
    in
    go 0 (t.depth - 1) t.tree ~f

  let ith_bit idx i = (idx lsr i) land 1 = 1

  let find_index (t : t) aid =
    List.Assoc.find t.indexes ~equal:Account_id.equal aid

  let allocate_index ({ T.current_location; indexes; _ } as t) account_id =
    let new_location =
      match current_location with None -> 0 | Some x -> x + 1
    in
    ( new_location
    , { t with
        current_location = Some new_location
      ; indexes = (account_id, new_location) :: indexes
      } )

  let get_exn ({ T.tree; depth; _ } as t) idx =
    let rec go i tree =
      match (i < 0, tree) with
      | true, Tree.Account acct ->
          acct
      | false, Node (_, l, r) ->
          let go_right = ith_bit idx i in
          if go_right then go (i - 1) r else go (i - 1) l
      | _, Hash h when Hash.equal h (empty_hash i) ->
          Lazy.force Account.empty
      | _ ->
          let expected_kind = if i < 0 then "n account" else " node" in
          let kind =
            match tree with
            | Account _ ->
                "n account"
            | Hash _ ->
                " hash"
            | Node _ ->
                " node"
          in
          failwithf
            !"Sparse_ledger.get: Bad index %i. Expected a%s, but got a%s at \
              depth %i. Tree = %{sexp:t}, tree_depth = %d"
            idx expected_kind kind (depth - i) t depth ()
    in
    go (depth - 1) tree

  let set_exn (t : t) idx acct =
    let rec go i tree =
      match (i < 0, tree) with
      | true, Tree.Account _ ->
          Tree.Account acct
      | false, Node (_, l, r) ->
          let l, r =
            let go_right = ith_bit idx i in
            if go_right then (l, go (i - 1) r) else (go (i - 1) l, r)
          in
          Node (Hash.merge ~height:i (hash l) (hash r), l, r)
      | false, Hash h when Hash.equal h (empty_hash i) ->
          let inner =
            if i > 0 then Tree.Hash (empty_hash (i - 1))
            else Tree.Account (Lazy.force Account.empty)
          in
          go i (Node (h, inner, inner))
      | true, Hash h when Hash.equal h (empty_hash i) ->
          Tree.Account acct
      | _ ->
          let expected_kind = if i < 0 then "n account" else " node" in
          let kind =
            match tree with
            | Account _ ->
                "n account"
            | Hash _ ->
                " hash"
            | Node _ ->
                " node"
          in
          failwithf
            "Sparse_ledger.set: Bad index %i. Expected a%s, but got a%s at \
             depth %i."
            idx expected_kind kind (t.depth - i) ()
    in
    { t with tree = go (t.depth - 1) t.tree }

  let path_exn { T.tree; depth; _ } idx =
    let rec go acc i tree =
      if i < 0 then acc
      else
        match tree with
        | Tree.Account _ ->
            failwithf "Sparse_ledger.path: Bad depth at index %i." idx ()
        | Hash h when Hash.equal h (empty_hash i) ->
            let inner =
              if i > 0 then Tree.Hash (empty_hash (i - 1))
              else Tree.Account (Lazy.force Account.empty)
            in
            go acc i (Tree.Node (h, inner, inner))
        | Hash _ ->
            failwithf "Sparse_ledger.path: Dead end at index %i." idx ()
        | Node (_, l, r) ->
            let go_right = ith_bit idx i in
            if go_right then go (`Right (hash l) :: acc) (i - 1) r
            else go (`Left (hash r) :: acc) (i - 1) l
    in
    go [] (depth - 1) tree
end

type ('hash, 'key, 'account) t = ('hash, 'key, 'account) T.t [@@deriving yojson]

let%test_module "sparse-ledger-test" =
  ( module struct
    module Account = struct
      module T = struct
        type t = { name : string; favorite_number : int }
        [@@deriving bin_io, equal, sexp, yojson]
      end

      include T

      let key { name; _ } = name

      let data_hash t = Md5.digest_string (Binable.to_string (module T) t)

      let gen =
        let open Quickcheck.Generator.Let_syntax in
        let%map name = String.quickcheck_generator
        and favorite_number = Int.quickcheck_generator in
        { name; favorite_number }

      let empty = lazy { name = ""; favorite_number = 0 }
    end

    module Hash = struct
      type t = Core_kernel.Md5.t [@@deriving sexp, compare]

      let equal h1 h2 = Int.equal (compare h1 h2) 0

      let to_yojson md5 = `String (Core_kernel.Md5.to_hex md5)

      let of_yojson = function
        | `String x ->
            Or_error.try_with (fun () -> Core_kernel.Md5.of_hex_exn x)
            |> Result.map_error ~f:Error.to_string_hum
        | _ ->
            Error "Expected a hex-encoded MD5 hash"

      let merge ~height x y =
        let open Md5 in
        digest_string
          (sprintf "sparse-ledger_%03d" height ^ to_binary x ^ to_binary y)

      let gen =
        Quickcheck.Generator.map String.quickcheck_generator
          ~f:Md5.digest_string
    end

    module Account_id = struct
      type t = string [@@deriving sexp, equal, yojson]
    end

    include Make (Hash) (Account_id) (Account)

    let gen =
      let open Quickcheck.Generator in
      let open Let_syntax in
      let indexes max_depth t =
        let rec go addr d = function
          | Tree.Account a ->
              [ (Account.key a, addr) ]
          | Hash _ ->
              []
          | Node (_, l, r) ->
              go addr (d - 1) l @ go (addr lor (1 lsl d)) (d - 1) r
        in
        go 0 (max_depth - 1) t
      in
      let rec prune_hash_branches = function
        | Tree.Hash h ->
            Tree.Hash h
        | Account a ->
            Account a
        | Node (h, l, r) -> (
            match (prune_hash_branches l, prune_hash_branches r) with
            | Hash _, Hash _ ->
                Hash h
            | l, r ->
                Node (h, l, r) )
      in
      let rec gen depth =
        if depth = 0 then Account.gen >>| fun a -> Tree.Account a
        else
          let t =
            let sub = gen (depth - 1) in
            let%map l = sub and r = sub in
            Tree.Node (Hash.merge ~height:(depth - 1) (hash l) (hash r), l, r)
          in
          weighted_union
            [ (1. /. 3., Hash.gen >>| fun h -> Tree.Hash h); (2. /. 3., t) ]
      in
      let%bind depth = Int.gen_incl 0 16 in
      let%map tree = gen depth >>| prune_hash_branches in
      let current_location =
        (* Except with negligible probability, every hash and account will be
           non-empty, so we behave as if the ledger is full. *)
        Some ((1 lsl depth) - 1)
      in
      { T.tree; depth; indexes = indexes depth tree; current_location }

    let%test_unit "iteri consistent indices with t.indexes" =
      Quickcheck.test gen ~f:(fun t ->
          let indexes = Int.Set.of_list (t.indexes |> List.map ~f:snd) in
          iteri t ~f:(fun i _ ->
              [%test_result: bool]
                ~message:
                  "Iteri index should be contained in the indexes auxillary \
                   structure"
                ~expect:true (Int.Set.mem indexes i) ) )

    let%test_unit "path_test" =
      Quickcheck.test gen ~f:(fun t ->
          let root = { t with indexes = []; tree = Hash (merkle_root t) } in
          let t' =
            List.fold t.indexes ~init:root ~f:(fun acc (_, index) ->
                let account = get_exn t index in
                add_path acc (path_exn t index) (Account.key account) account )
          in
          assert (Tree.equal Hash.equal Account.equal t'.tree t.tree) )
  end )
