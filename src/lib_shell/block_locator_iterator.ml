(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

let estimated_length locator =
  let (_head, hist) = Block_locator.raw locator in
  let rec loop acc step cpt = function
    | [] -> acc
    | _ :: hist ->
        if cpt = 0 then
          loop (acc+step) (step*2) 9 hist
        else
          loop (acc+step) step (cpt-1) hist
  in
  loop 1 1 9 hist

let fold ~f acc locator =
  let (head, hist) = Block_locator.raw locator in
  let rec loop step cpt acc = function
    | [] | [_] -> acc
    | block :: (pred :: rem as hist) ->
        let step, cpt =
          if cpt = 0 then
            2 * step, 9
          else
            step, cpt - 1 in
        let acc = f acc ~block ~pred ~step ~strict_step:(rem <> []) in
        loop step cpt acc hist
  in
  loop 1 10 acc (Block_header.hash head :: hist)

type step = {
  block: Block_hash.t ;
  predecessor: Block_hash.t ;
  step: int ;
  strict_step: bool ;
}

let to_steps locator =
  fold
    ~f:begin fun acc ~block ~pred ~step ~strict_step -> {
        block ; predecessor = pred ; step ; strict_step ;
      } :: acc
    end
    [] locator

let block_validity chain_state block : Block_locator.validity Lwt.t =
  State.Block.known chain_state block >>= function
  | false ->
      if Block_hash.equal block (State.Chain.faked_genesis_hash chain_state) then
        Lwt.return Block_locator.Known_valid
      else
        Lwt.return Block_locator.Unknown
  | true ->
      State.Block.known_invalid chain_state block >>= function
      | true ->
          Lwt.return Block_locator.Known_invalid
      | false ->
          Lwt.return Block_locator.Known_valid

let known_ancestor chain_state locator =
  Block_locator.unknown_prefix (block_validity chain_state) locator >>= function
  | None -> Lwt.return_none
  | Some (tail, locator) ->
      if Block_hash.equal tail (State.Chain.faked_genesis_hash chain_state) then
        State.Block.read_exn
          chain_state (State.Chain.genesis chain_state).block >>= fun genesis ->
        Lwt.return_some (genesis, locator)
      else
        State.Block.read_exn chain_state tail >>= fun block ->
        Lwt.return_some (block, locator)

let find_new chain_state locator sz =
  let rec path sz acc h =
    if sz <= 0 then Lwt.return (List.rev acc)
    else
      State.read_chain_data chain_state begin fun chain_store _data ->
        Store.Chain_data.In_main_branch.read_opt (chain_store, h)
      end >>= function
      | None -> Lwt.return (List.rev acc)
      | Some s -> path (sz-1) (s :: acc) s in
  known_ancestor chain_state locator >>= function
  | None -> Lwt.return_nil
  | Some (known, _) ->
      Chain.head chain_state >>= fun head ->
      Chain_traversal.common_ancestor known head >>= fun ancestor ->
      path sz [] (State.Block.hash ancestor)

