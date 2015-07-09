(*
MSAT is free software, using the Apache license, see file LICENSE
Copyright 2014 Guillaume Bury
Copyright 2014 Simon Cruanes
*)

module type S = Res_intf.S

module Make(L : Log_intf.S)(St : Solver_types.S) = struct

  (* Type definitions *)
  type lemma = St.proof
  type clause = St.clause
  type atom = St.atom
  type int_cl = clause * St.atom list

  type node =
    | Assumption
    | Lemma of lemma
    | Resolution of atom * int_cl * int_cl
    (* lits, c1, c2 with lits the literals used to resolve c1 and c2 *)

  exception Insuficient_hyps
  exception Resolution_error of string

  (* Proof graph *)
  let hash_cl cl =
    Hashtbl.hash (List.map (fun a -> St.(a.aid)) cl)

  let equal_cl cl_c cl_d =
    try
      List.for_all2 (==) cl_c cl_d
    with Invalid_argument _ ->
      false

  module H = Hashtbl.Make(struct
      type t = St.atom list
      let hash = hash_cl
      let equal = equal_cl
    end)
  let proof : node H.t = H.create 1007;;

  (* Misc functions *)
  let equal_atoms a b = St.(a.aid) = St.(b.aid)
  let compare_atoms a b = Pervasives.compare St.(a.aid) St.(b.aid)

  let merge = List.merge compare_atoms

  let _c = ref 0
  let fresh_pcl_name () = incr _c; "P" ^ (string_of_int !_c)

  (* Printing functions *)
  let rec print_cl fmt = function
    | [] -> Format.fprintf fmt "[]"
    | [a] -> St.print_atom fmt a
    | a :: ((_ :: _) as r) -> Format.fprintf fmt "%a ∨ %a" St.print_atom a print_cl r

  (* Compute resolution of 2 clauses *)
  let resolve l =
    let rec aux resolved acc = function
      | [] -> resolved, acc
      | [a] -> resolved, a :: acc
      | a :: b :: r ->
        if equal_atoms a b then
          aux resolved (a :: acc) r
        else if equal_atoms St.(a.neg) b then
          aux (St.(a.var.pa) :: resolved) acc r
        else
          aux resolved (a :: acc) (b :: r)
    in
    let resolved, new_clause = aux [] [] l in
    resolved, List.rev new_clause

  (* List.sort_uniq is only since 4.02.0 *)
  let sort_uniq compare l =
    let rec aux = function
      | x :: ((y :: _) as r) -> if compare x y = 0 then aux r else x :: aux r
      | l -> l
    in
    aux (List.sort compare l)

  let to_list c =
    let v = St.(c.atoms) in
    let l = ref [] in
    for i = 0 to Vec.size v - 1 do
      l := (Vec.get v i) :: !l
    done;
    let res = sort_uniq compare_atoms !l in
    let l, _ = resolve res in
    if l <> [] then
      L.debug 3 "Input clause is a tautology";
    res

  let print_clause fmt c = print_cl fmt (to_list c)

  (* Adding hyptoheses *)
  let has_been_proved c = H.mem proof (to_list c)

  let is_proved (c, cl) =
    if H.mem proof cl then
      true
    else if not St.(c.learnt) then begin
      H.add proof cl Assumption;
      true
    end else match St.(c.cpremise) with
      | St.Lemma p -> H.add proof cl (Lemma p); true
      | St.History _ -> false

  let is_proven c = is_proved (c, to_list c)

  let add_res (c, cl_c) (d, cl_d) =
    L.debug 7 "  Resolving clauses :";
    L.debug 7 "    %a" St.pp_clause c;
    L.debug 7 "    %a" St.pp_clause d;
    assert (is_proved (c, cl_c));
    assert (is_proved (d, cl_d));
    let l = merge cl_c cl_d in
    let resolved, new_clause = resolve l in
    match resolved with
    | [] -> raise (Resolution_error "No literal to resolve over")
    | [a] ->
      H.add proof new_clause (Resolution (a, (c, cl_c), (d, cl_d)));
      let new_c = St.make_clause (fresh_pcl_name ()) new_clause (List.length new_clause) true St.(History [c; d]) in
      L.debug 5 "New clause : %a" St.pp_clause new_c;
      new_c, new_clause
    | _ -> raise (Resolution_error "Resolved to a tautology")

  let rec diff_learnt acc l l' =
    match l, l' with
    | [], _ -> l' @ acc
    | a :: r, b :: r' ->
      if equal_atoms a b then
        diff_learnt acc r r'
      else
        diff_learnt (b :: acc) l r'
    | _ -> raise (Resolution_error "Impossible to derive correct clause")

  let clause_unit a = match St.(a.var.level, a.var.reason) with
    | 0, St.Bcp Some c -> c, to_list c
    | _ ->
      raise (Resolution_error "Could not find a reason needed to resolve")

  let need_clause (c, cl) =
    if is_proved (c, cl) then
      []
    else
      match St.(c.cpremise) with
      | St.History l -> l
      | St.Lemma _ -> assert false

  let rec add_clause c cl l = (* We assume that all clauses in l are already proved ! *)
    match l with
    | a :: r ->
      L.debug 5 "Resolving (with history) %a" St.pp_clause c;
      let temp_c, temp_cl = List.fold_left add_res a r in
      L.debug 10 " Switching to unit resolutions";
      let new_c, new_cl = (ref temp_c, ref temp_cl) in
      while not (equal_cl cl !new_cl) do
        let unit_to_use = diff_learnt [] cl !new_cl in
        let unit_r = List.map (fun a -> clause_unit a) unit_to_use in
        do_clause (List.map fst unit_r);
        let temp_c, temp_cl = List.fold_left add_res (!new_c, !new_cl) unit_r in
        new_c := temp_c;
        new_cl := temp_cl;
      done
    | _ -> assert false

  and do_clause = function
    | [] -> ()
    | c :: r ->
      let cl = to_list c in
      match need_clause (c, cl) with
      | [] -> do_clause r
      | history ->
        let history_cl = List.rev_map (fun c -> c, to_list c) history in
        let to_prove = List.filter (fun (c, cl) -> not (is_proved (c, cl))) history_cl in
        let to_prove = (List.rev_map fst to_prove) in
        begin match to_prove with
          | [] ->
            add_clause c cl history_cl;
            do_clause r
          | _ -> do_clause (to_prove @ (c :: r))
        end

  let prove c =
    L.debug 3 "Proving : %a" St.pp_clause c;
    do_clause [c];
    L.debug 3 "Proved : %a" St.pp_clause c

  let rec prove_unsat_cl (c, cl) = match cl with
    | [] -> true
    | a :: r ->
      L.debug 2 "Eliminating %a in %a" St.pp_atom a St.pp_clause c;
      let d = match St.(a.var.level, a.var.reason) with
        | 0, St.Bcp Some d -> d
        | _ -> raise Exit
      in
      prove d;
      let cl_d = to_list d in
      prove_unsat_cl (add_res (c, cl) (d, cl_d))

  let prove_unsat_cl c =
    try
      prove_unsat_cl c
    with Exit ->
      false

  let learn v =
    Vec.iter (fun c -> L.debug 15 "history : %a" St.pp_clause c) v;
    Vec.iter prove v

  let assert_can_prove_unsat c =
    L.debug 1 "=================== Proof =====================";
    prove c;
    if not (prove_unsat_cl (c, to_list c)) then
      raise Insuficient_hyps

  (* Interface exposed *)
  type proof_node = {
    conclusion : clause;
    step : step;
  }
  and proof = clause * atom list
  and step =
    | Hypothesis
    | Lemma of lemma
    | Resolution of proof * proof * atom

  let expand (c, cl) =
    let st = match H.find proof cl with
      | Assumption -> Hypothesis
      | Lemma l -> Lemma l
      | Resolution (a, cl_c, cl_d) ->
        Resolution (cl_c, cl_d, a)
    in
    { conclusion = c; step = st }

  let prove_unsat c =
    assert_can_prove_unsat c;
    (St.empty_clause, [])

  (* Compute unsat-core *)
  let compare_cl c d =
    let rec aux = function
      | [], [] -> 0
      | a :: r, a' :: r' -> begin match compare_atoms a a' with
          | 0 -> aux (r, r')
          | x -> x
        end
      | _ :: _ , [] -> -1
      | [], _ :: _ -> 1
    in
    aux (to_list c, to_list d)

  let unsat_core proof =
    let rec aux acc proof =
      let p = expand proof in
      match p.step with
      | Hypothesis | Lemma _ -> p.conclusion :: acc
      | Resolution (proof1, proof2, _) ->
        aux (aux acc proof1) proof2
    in
    sort_uniq compare_cl (aux [] proof)

  (* Iter on proofs *)
  type task =
    | Enter of proof
    | Leaving of proof

  let pop s = try Some (Stack.pop s) with Stack.Empty -> None

  let rec fold_aux s h f acc =
    match pop s with
    | None -> acc
    | Some (Leaving ((_, cl) as p)) ->
      H.add h cl true;
      fold_aux s h f (f acc (expand p))
    | Some (Enter ((_, cl) as p)) ->
      if not (H.mem h cl) then begin
        Stack.push (Leaving p) s;
        let node = expand p in
        begin match node.step with
        | Resolution (p1, p2, _) ->
          Stack.push (Enter p2) s;
          Stack.push (Enter p1) s
        | _ -> ()
        end
      end;
      fold_aux s h f acc

  let fold f acc p =
    let h = H.create 42 in
    let s = Stack.create () in
    Stack.push (Enter p) s;
    fold_aux s h f acc

  (* Dot proof printing *)
  module Dot = struct
    let _i = ref 0
    let new_id () = incr _i; "id_" ^ (string_of_int !_i)

    let ids : (clause, (bool * string)) Hashtbl.t = Hashtbl.create 1007;;
    let c_id c =
      try
        snd (Hashtbl.find ids c)
      with Not_found ->
        let id = new_id () in
        Hashtbl.add ids c (false, id);
        id

    let clear_ids () =
      Hashtbl.iter (fun c (_, id) -> Hashtbl.replace ids c (false, id)) ids

    let is_drawn c =
      ignore (c_id c);
      fst (Hashtbl.find ids c)

    let has_drawn c =
      if not (is_drawn c) then
        let b, id = Hashtbl.find ids c in
        Hashtbl.replace ids c (true, id)
      else
        ()

    let print_dot_rule opt f arg fmt cl =
      Format.fprintf fmt "%s [shape=plaintext, label=<<TABLE %s %s>%a</TABLE>>];@\n"
        (c_id cl) "BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\"" opt f arg

    let print_dot_edge id_c fmt id_d =
      Format.fprintf fmt "%s -> %s;@\n" id_c id_d

    let print_res_atom id fmt a =
      Format.fprintf fmt "%s [label=\"%a\"]" id St.print_atom a

    let print_res_node concl p1 p2 fmt atom =
      let id = new_id () in
      Format.fprintf fmt "%a;@\n%a%a%a"
        (print_res_atom id) atom
        (print_dot_edge (c_id concl)) id
        (print_dot_edge id) (c_id p1)
        (print_dot_edge id) (c_id p2)

    let color s = match s.[0] with
      | 'E' -> "BGCOLOR=\"GREEN\""
      | 'L' -> "BGCOLOR=\"GREEN\""
      | _ -> "BGCOLOR=\"GREY\""

    let rec print_dot_proof fmt p =
      if not (is_drawn p.conclusion) then begin
        has_drawn p.conclusion;
        match p.step with
        | Hypothesis ->
          let aux fmt () =
            Format.fprintf fmt "<TR><TD colspan=\"2\">%a</TD></TR><TR><TD>Hypothesis</TD><TD>%s</TD></TR>"
              print_clause p.conclusion St.(p.conclusion.name)
          in
          print_dot_rule "BGCOLOR=\"LIGHTBLUE\"" aux () fmt p.conclusion
        | Lemma proof ->
          let name, f_args, t_args, color = St.proof_debug proof in
          let color = match color with None -> "YELLOW" | Some c -> c in
          let aux fmt () =
            Format.fprintf fmt "<TR><TD colspan=\"2\">%a</TD></TR><TR><TD BGCOLOR=\"%s\" rowspan=\"%d\">%s</TD>"
              print_clause p.conclusion color (max (List.length f_args + List.length t_args) 1) name;
            if f_args <> [] then
              Format.fprintf fmt "<TD>%a</TD></TR>%a%a" St.print_atom (List.hd f_args)
                (fun fmt -> List.iter (fun a -> Format.fprintf fmt "<TR><TD>%a</TD></TR>" St.print_atom a)) (List.tl f_args)
                (fun fmt -> List.iter (fun v -> Format.fprintf fmt "<TR><TD>%a</TD></TR>" St.print_lit v)) t_args
            else if t_args <> [] then
              Format.fprintf fmt "<TD>%a</TD></TR>%a" St.print_lit (List.hd t_args)
                (fun fmt -> List.iter (fun v -> Format.fprintf fmt "<TR><TD>%a</TD></TR>" St.print_lit v)) (List.tl t_args)
            else
              Format.fprintf fmt "<TD></TD></TR>"
          in
          print_dot_rule "BGCOLOR=\"LIGHTBLUE\"" aux () fmt p.conclusion
        | Resolution (proof1, proof2, a) ->
          let aux fmt () =
            Format.fprintf fmt "<TR><TD colspan=\"2\">%a</TD></TR><TR><TD>%s</TD><TD>%s</TD></TR>"
              print_clause p.conclusion
              "Resolution" St.(p.conclusion.name)
          in
          let p1 = expand proof1 in
          let p2 = expand proof2 in
          Format.fprintf fmt "%a%a%a%a"
            (print_dot_rule (color p.conclusion.St.name) aux ()) p.conclusion
            (print_res_node p.conclusion p1.conclusion p2.conclusion) a
            print_dot_proof p1
            print_dot_proof p2
      end

    let print fmt proof =
      clear_ids ();
      Format.fprintf fmt "digraph proof {@\n%a@\n}@." print_dot_proof (expand proof)
  end

  let print_dot = Dot.print

end

