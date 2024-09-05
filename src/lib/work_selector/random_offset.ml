open Core_kernel

(** The work selection method implemented here is the following. We distinguish
two cases:
    1. The work pool is updated: a random [offset] is generated. The selected
    work is the [offset]-th one of the expensive work list.
    2. As long as the pool stays the same, the works are selected sequentially
    from the offset. If the end of the work list is reached, the next works are
    selected sequentially from the beginning of the list. *)
module Make
    (Inputs : Intf.Inputs_intf)
    (Lib : Intf.Lib_intf with module Inputs := Inputs) =
struct
  module Offset = struct
    (** The initialization for the first offset can be 0; as the first
   [previous_length] 0, any non-empty list will trigger an update of the offset. *)
    let offset = ref 0

    (** The previous length of expensive works [work] got through *)
    let prev_length = ref 0

    (** This function maintains [prev_length] & [offset] up do date.
        When the pool is not updated, we consider that its length should stay
        the same or decrease by 1 ([!prev_length - new_length] = 0 or 1). If an
        other behavior is observed, the pool is considered updated and a new
        [offset] is generated randomly, uniformly chosen between 0 and
        [new_length]. *)
    let update ~logger ~new_length =
     Logger.info logger ~module_:__MODULE__ ~location:__LOC__ ("update : new_length is %d") new_length ;
     Logger.info logger ~module_:__MODULE__ ~location:__LOC__ ("update : offset is %d, prev_length - new_length is %d") !offset (!prev_length - new_length) ;
      let () =
        if new_length = !prev_length || new_length = !prev_length - 1 then ()
        else let () = offset := Random.int 100
      in
      let () = Logger.info logger ~module_:__MODULE__ ~location:__LOC__ ("update : offset updated to %d, prev_length - new_length is %d") !offset  (!prev_length - new_length) in ()
      in
      prev_length := new_length

    (** Because of the [offset] being constant and the [expensive_work] list
    reducing in size, a case where [offset] ends up greater than the list
    length may happen. In that case, we go back to the beginning of the list,
    by resetting [offset] to 0.
  /!\ fails if [expensive_work] is empty! *)
    let get_nth expensive_work =
      try List.nth_exn expensive_work !offset
      with _ ->
        (* Raising an error here means that offset is now too large for the
           list -> back to the beginning with offset at 0 *)
        offset := 0 ;
        List.nth_exn expensive_work !offset
  end

  let work ~snark_pool ~fee ~logger (state : Lib.State.t) =
    Lib.State.remove_old_assignments state ~logger ;
    let unseen_jobs = Lib.State.all_unseen_works state in
    match Lib.get_expensive_work ~snark_pool ~fee unseen_jobs with
    | [] ->
        None
    | expensive_work ->
        Offset.update ~logger ~new_length:(List.length expensive_work) ;
        let x = Offset.get_nth expensive_work in
        Lib.State.set state x ; Some x

  let remove = Lib.State.remove

  let pending_work_statements = Lib.pending_work_statements
end

let%test_module "test" =
  ( module struct
    module Test = Test.Make_test (Make)
  end )
