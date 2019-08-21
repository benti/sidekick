(** {1 Implementation of a Solver using Msat} *)

module Vec = Msat.Vec
module Log = Msat.Log
module IM = Util.Int_map

module type ARG = sig
  include Sidekick_core.TERM_PROOF
  val cc_view : Term.t -> (Fun.t, Term.t, Term.t Iter.t) Sidekick_core.CC_view.t
end

module type S = Sidekick_core.SOLVER

module Make(A : ARG)
  : S with module A = A
= struct
  module A = A
  module T = A.Term
  module Ty = A.Ty
  type term = T.t
  type ty = Ty.t
  type lemma = A.Proof.t

  module Lit_ = struct
    type t = {
      lit_term: term;
      lit_sign : bool
    }

    let[@inline] neg l = {l with lit_sign=not l.lit_sign}
    let[@inline] sign t = t.lit_sign
    let[@inline] term (t:t): term = t.lit_term

    let make ~sign t = {lit_sign=sign; lit_term=t}

    let atom tst ?(sign=true) (t:term) : t =
      let t, sign' = T.abs tst t in
      let sign = if not sign' then not sign else sign in
      make ~sign t

    let equal a b =
      a.lit_sign = b.lit_sign &&
      T.equal a.lit_term b.lit_term

    let hash a =
      let sign = a.lit_sign in
      CCHash.combine3 2 (CCHash.bool sign) (T.hash a.lit_term)

    let pp out l =
      if l.lit_sign then T.pp out l.lit_term
      else Format.fprintf out "(@[@<1>¬@ %a@])" T.pp l.lit_term

    let apply_sign t s = if s then t else neg t
    let norm_sign l = if l.lit_sign then l, true else neg l, false
    let norm l = let l, sign = norm_sign l in l, if sign then Msat.Same_sign else Msat.Negated
  end

  type lit = Lit_.t

  (* actions from msat *)
  type msat_acts = (Msat.void, lit, Msat.void, A.Proof.t) Msat.acts

  (* the full argument to the congruence closure *)
  module CC_A = struct
    module A = A
    module Lit = Lit_
    let cc_view = A.cc_view

    module Actions = struct
      type t = msat_acts
      let[@inline] raise_conflict a lits pr =
        a.Msat.acts_raise_conflict lits pr
      let[@inline] propagate a lit ~reason pr =
        let reason = Msat.Consequence (fun () -> reason(), pr) in 
        a.Msat.acts_propagate lit reason
    end
  end

  module CC = Sidekick_cc.Make(CC_A)
  module Expl = CC.Expl
  module N = CC.N

  (** Internal solver, given to theories and to Msat *)
  module Solver_internal = struct
    module A = A
    module CC_A = CC_A
    module Lit = Lit_
    module CC = CC
    module N = CC.N
    type term = T.t
    type ty = Ty.t
    type lit = Lit.t
    type term_state = T.state

    type th_states = 
      | Ths_nil
      | Ths_cons : {
          st: 'a;
          push_level: 'a -> unit;
          pop_levels: 'a -> int -> unit;
          next: th_states;
        } -> th_states

    type actions = msat_acts

    module Simplify = struct
      type t = {
        tst: term_state;
        mutable hooks: hook list;
        cache: T.t T.Tbl.t;
      }
      and hook = t -> term -> term option

      let create tst : t = {tst; hooks=[]; cache=T.Tbl.create 32;}
      let[@inline] tst self = self.tst
      let add_hook self f = self.hooks <- f :: self.hooks
      let clear self = T.Tbl.clear self.cache

      let normalize (self:t) (t:T.t) : T.t =
        (* compute and cache normal form of [t] *)
        let rec aux t =
          match T.Tbl.find self.cache t with
          | u -> u
          | exception Not_found ->
            let u = aux_rec t self.hooks in
            T.Tbl.add self.cache t u;
            u
        (* try each function in [hooks] successively, and rewrite subterms *)
        and aux_rec t hooks = match hooks with
          | [] ->
            let u = T.map_shallow self.tst aux t in
            if T.equal t u then t else aux u
          | h :: hooks_tl ->
            match h self t with
            | None -> aux_rec t hooks_tl
            | Some u when T.equal t u -> aux_rec t hooks_tl
            | Some u -> aux u
        in
        aux t
    end
    type simplify_hook = Simplify.hook

    type t = {
      tst: T.state; (** state for managing terms *)
      cc: CC.t lazy_t; (** congruence closure *)
      stat: Stat.t;
      count_axiom: int Stat.counter;
      count_preprocess_clause: int Stat.counter;
      count_conflict: int Stat.counter;
      count_propagate: int Stat.counter;
      mutable on_progress: unit -> unit;
      simp: Simplify.t;
      mutable preprocess: preprocess_hook list;
      preprocess_cache: T.t T.Tbl.t;
      mutable th_states : th_states; (** Set of theories *)
      mutable on_partial_check: (t -> actions -> lit Iter.t -> unit) list;
      mutable on_final_check: (t -> actions -> lit Iter.t -> unit) list;
    }

    and preprocess_hook =
      t ->
      mk_lit:(term -> lit) ->
      add_clause:(lit list -> unit) ->
      term -> term option

    type solver = t

    module Formula = struct
      include Lit
      let norm lit =
        let lit', sign = norm_sign lit in
        lit', if sign then Msat.Same_sign else Msat.Negated
    end
    module Eq_class = CC.N
    module Expl = CC.Expl

    type proof = A.Proof.t

    let[@inline] cc (t:t) = Lazy.force t.cc
    let[@inline] tst t = t.tst

    let simplifier self = self.simp
    let simp_t self (t:T.t) : T.t = Simplify.normalize self.simp t
    let add_simplifier (self:t) f : unit = Simplify.add_hook self.simp f

    let add_preprocess self f = self.preprocess <- f :: self.preprocess

    let[@inline] raise_conflict self acts c : 'a =
      Stat.incr self.count_conflict;
      acts.Msat.acts_raise_conflict c A.Proof.default

    let[@inline] propagate self acts p cs : unit =
      Stat.incr self.count_propagate;
      acts.Msat.acts_propagate p (Msat.Consequence (fun () -> cs(), A.Proof.default))

    let[@inline] propagate_l self acts p cs : unit =
      propagate self acts p (fun()->cs)

    let add_sat_clause_ self acts ~keep lits : unit =
      Stat.incr self.count_axiom;
      acts.Msat.acts_add_clause ~keep lits A.Proof.default

    let preprocess_lit_ (self:t) ~add_clause (lit:lit) : lit =
      let mk_lit t = Lit.atom self.tst t in
      (* compute and cache normal form of [t] *)
      let rec aux t =
        match T.Tbl.find self.preprocess_cache t with
        | u -> u
        | exception Not_found ->
          (* first, map subterms *)
          let u = T.map_shallow self.tst aux t in
          (* then rewrite *)
          let u = aux_rec u self.preprocess in
          T.Tbl.add self.preprocess_cache t u;
          u
      (* try each function in [hooks] successively *)
      and aux_rec t hooks = match hooks with
        | [] -> t
        | h :: hooks_tl ->
          match h self ~mk_lit ~add_clause t with
          | None -> aux_rec t hooks_tl
          | Some u ->
            Log.debugf 30 
              (fun k->k "(@[msat-solver.preprocess.step@ :from %a@ :to %a@])"
                  T.pp t T.pp u);
            aux u
      in
      let t = Lit.term lit |> simp_t self |> aux in
      let lit' = Lit.atom self.tst ~sign:(Lit.sign lit) t in
      Log.debugf 10
        (fun k->k "(@[msat-solver.preprocess@ :lit %a@ :into %a@])" Lit.pp lit Lit.pp lit');
      lit'

    let mk_lit self acts ?sign t =
      let add_clause lits =
        Stat.incr self.count_preprocess_clause;
        add_sat_clause_ self acts ~keep:true lits
      in
      preprocess_lit_ self ~add_clause @@ Lit.atom self.tst ?sign t

    let[@inline] add_clause_temp self acts lits : unit =
      add_sat_clause_ self acts ~keep:false lits

    let[@inline] add_clause_permanent self acts lits : unit =
      add_sat_clause_ self acts ~keep:true lits

    let add_lit _self acts lit : unit = acts.Msat.acts_mk_lit lit

    let add_lit_t self acts ?sign t = add_lit self acts (mk_lit self acts ?sign t)

    let on_final_check self f = self.on_final_check <- f :: self.on_final_check
    let on_partial_check self f = self.on_partial_check <- f :: self.on_partial_check
    let on_cc_new_term self f = CC.on_new_term (cc self) f
    let on_cc_pre_merge self f = CC.on_pre_merge (cc self) f
    let on_cc_post_merge self f = CC.on_post_merge (cc self) f
    let on_cc_conflict self f = CC.on_conflict (cc self) f
    let on_cc_propagate self f = CC.on_propagate (cc self) f

    let cc_add_term self t = CC.add_term (cc self) t
    let cc_find self n = CC.find (cc self) n
    let cc_merge self _acts n1 n2 e = CC.merge (cc self) n1 n2 e
    let cc_merge_t self acts t1 t2 e =
      cc_merge self acts (cc_add_term self t1) (cc_add_term self t2) e
    let cc_raise_conflict_expl self acts e =
      CC.raise_conflict_from_expl (cc self) acts e

    (** {2 Interface with the SAT solver} *)

    let rec push_lvl_ = function
      | Ths_nil -> ()
      | Ths_cons r -> r.push_level r.st; push_lvl_ r.next

    let rec pop_lvls_ n = function
      | Ths_nil -> ()
      | Ths_cons r -> r.pop_levels r.st n; pop_lvls_ n r.next

    let push_level (self:t) : unit =
      CC.push_level (cc self);
      push_lvl_ self.th_states

    let pop_levels (self:t) n : unit =
      CC.pop_levels (cc self) n;
      pop_lvls_ n self.th_states

    (* handle a literal assumed by the SAT solver *)
    let assert_lits_ ~final (self:t) (acts:actions) (lits:Lit.t Iter.t) : unit =
      Msat.Log.debugf 2
        (fun k->k "(@[<hv1>@{<green>msat-solver.assume_lits@}%s@ %a@])"
            (if final then "[final]" else "") (Util.pp_seq ~sep:"; " Lit.pp) lits);
      (* transmit to CC *)
      let cc = cc self in
      if not final then (
        CC.assert_lits cc lits;
      );
      (* transmit to theories. *)
      CC.check cc acts;
      if final then (
        List.iter (fun f -> f self acts lits) self.on_final_check;
      ) else (
        List.iter (fun f -> f self acts lits) self.on_partial_check;
      );
      ()

    let[@inline] iter_atoms_ acts : _ Iter.t =
      fun f ->
      acts.Msat.acts_iter_assumptions
        (function
          | Msat.Lit a -> f a
          | Msat.Assign _ -> assert false)

    (* propagation from the bool solver *)
    let check_ ~final (self:t) (acts: msat_acts) =
      let iter = iter_atoms_ acts in
      Msat.Log.debugf 5 (fun k->k "(msat-solver.assume :len %d)" (Iter.length iter));
      self.on_progress();
      assert_lits_ ~final self acts iter

    (* propagation from the bool solver *)
    let[@inline] partial_check (self:t) (acts:_ Msat.acts) : unit =
      check_ ~final:false self acts

    (* perform final check of the model *)
    let[@inline] final_check (self:t) (acts:_ Msat.acts) : unit =
      check_ ~final:true self acts

    (* TODO
    let mk_model (self:t) lits : Model.t =
      let m =
        Iter.fold
          (fun m (Th_state ((module Th),st)) -> Th.mk_model st lits m)
          Model.empty (theories self)
      in
      (* now complete model using CC *)
      CC.mk_model (cc self) m
       *)

    let create ~stat (tst:A.Term.state) () : t =
      let rec self = {
        tst;
        cc = lazy (
          (* lazily tie the knot *)
          CC.create ~size:`Big self.tst;
        );
        th_states=Ths_nil;
        stat;
        simp=Simplify.create tst;
        on_progress=(fun () -> ());
        preprocess=[];
        preprocess_cache=T.Tbl.create 32;
        count_axiom = Stat.mk_int stat "solver.th-axioms";
        count_preprocess_clause = Stat.mk_int stat "solver.preprocess-clause";
        count_propagate = Stat.mk_int stat "solver.th-propagations";
        count_conflict = Stat.mk_int stat "solver.th-conflicts";
        on_partial_check=[];
        on_final_check=[];
      } in
      ignore (Lazy.force @@ self.cc : CC.t);
      self
  end
  module Lit = Solver_internal.Lit

  (** the parametrized SAT Solver *)
  module Sat_solver = Msat.Make_cdcl_t(Solver_internal)

  module Atom = Sat_solver.Atom
  module Proof = struct
    include Sat_solver.Proof
    module Dot = Msat_backend.Dot.Make(Sat_solver)(Msat_backend.Dot.Default(Sat_solver))
    let pp_dot = Dot.pp
  end

  type proof = Proof.t

  (* main solver state *)
  type t = {
    si: Solver_internal.t;
    solver: Sat_solver.t;
    stat: Stat.t;
    count_clause: int Stat.counter;
    count_solve: int Stat.counter;
    (* config: Config.t *)
  }
  type solver = t

  module type THEORY = sig
    type t
    val name : string
    val create_and_setup : Solver_internal.t -> t
    val push_level : t -> unit
    val pop_levels : t -> int -> unit
  end

  type theory = (module THEORY)
  type 'a theory_p = (module THEORY with type t = 'a)

  (** {2 Main} *)

  let add_theory_p (type a) (self:t) (th:a theory_p) : a =
    let (module Th) = th in
    Log.debugf 2
      (fun k-> k "(@[msat-solver.add-theory@ :name %S@])" Th.name);
    let st = Th.create_and_setup self.si in
    (* add push/pop to the internal solver *)
    begin
      let open Solver_internal in
      self.si.th_states <- Ths_cons {
          st;
          push_level=Th.push_level;
          pop_levels=Th.pop_levels;
          next=self.si.th_states;
        };
    end;
    st

  let add_theory (self:t) (th:theory) : unit =
    let (module Th) = th in
    ignore (add_theory_p self (module Th))

  let add_theory_l self = List.iter (add_theory self)

  (* create a new solver *)
  let create ?(stat=Stat.global) ?size ?store_proof ~theories tst () : t =
    Log.debug 5 "msat-solver.create";
    let si = Solver_internal.create ~stat tst () in
    let self = {
      si;
      solver=Sat_solver.create ?store_proof ?size si;
      stat;
      count_clause=Stat.mk_int stat "solver.add-clause";
      count_solve=Stat.mk_int stat "solver.solve";
    } in
    add_theory_l self theories;
    (* assert [true] and [not false] *)
    begin
      let tst = Solver_internal.tst self.si in
      Sat_solver.assume self.solver [
        [Lit.atom tst @@ T.bool tst true];
      ] A.Proof.default;
    end;
    self

  let[@inline] solver self = self.solver
  let[@inline] cc self = Solver_internal.cc self.si
  let[@inline] stats self = self.stat
  let[@inline] tst self = Solver_internal.tst self.si

  let[@inline] mk_atom_lit_ self lit : Atom.t = Sat_solver.make_atom self.solver lit

  let mk_atom_t_ self t : Atom.t =
    let lit = Lit.atom (tst self) t in
    mk_atom_lit_ self lit

  (* map boolean subterms to literals *)
  let add_bool_subterms_ (self:t) (t:T.t) : unit =
    T.iter_dag t
    |> Iter.filter (fun t -> Ty.is_bool @@ T.ty t)
    |> Iter.filter
      (fun t -> match A.cc_view t with
         | Sidekick_core.CC_view.Not _ -> false (* will process the subterm just later *)
         | _ -> true)
    |> Iter.iter
      (fun sub ->
         Log.debugf 5 (fun k->k  "(@[solver.map-bool-subterm-to-lit@ :subterm %a@])" T.pp sub);
         (* ensure that msat has a boolean atom for [sub] *)
         let atom = mk_atom_t_ self sub in
         (* also map [sub] to this atom in the congruence closure, for propagation *)
         let cc = cc self in
         CC.set_as_lit cc (CC.add_term cc sub ) (Sat_solver.Atom.formula atom);
         ())

  let rec mk_atom_lit self lit : Atom.t =
    let lit = preprocess_lit_ self lit in
    add_bool_subterms_ self (Lit.term lit);
    Sat_solver.make_atom self.solver lit

  and preprocess_lit_ self lit : Lit.t =
      Solver_internal.preprocess_lit_
        ~add_clause:(fun lits ->
            (* recursively add these sub-literals, so they're also properly processed *)
            Stat.incr self.si.count_preprocess_clause;
            let atoms = List.map (mk_atom_lit self) lits in
            Sat_solver.add_clause self.solver atoms A.Proof.default)
        self.si lit

  let[@inline] mk_atom_t self ?sign t : Atom.t =
    let lit = Lit.atom (tst self) ?sign t in
    mk_atom_lit self lit

  (** {2 Result} *)

  module Unknown = struct
    type t =
      | U_timeout
      | U_max_depth
      | U_incomplete

    let pp out = function
      | U_timeout -> Fmt.string out "timeout"
      | U_max_depth -> Fmt.string out "max depth reached"
      | U_incomplete -> Fmt.string out "incomplete fragment"
  end [@@ocaml.warning "-37"]

  (* TODO *)
  module Value = struct
    type t = unit
    let equal _ _ = true
    let hash _ = 0
    let ty _ = Ty.bool
    let pp out _ = Fmt.string out "<value>"
  end

  (* TODO *)
  module Model = struct
    type t = unit
    let empty = ()
    let mem _ _ = false
    let find _ _ = None
    let eval _ _ = None
    let pp out _ = Fmt.string out "<model>"
  end

  (* TODO
  type model = A.Model.t
  let pp_model = Model.pp
     *)

  type res =
    | Sat of Model.t
    | Unsat of {
        proof: proof option;
        unsat_core: Atom.t list lazy_t;
      }
    | Unknown of Unknown.t
    (** Result of solving for the current set of clauses *)

  (** {2 Main} *)

  (* print all terms reachable from watched literals *)
  let pp_term_graph _out (_:t) =
    () (* TODO *)

  let pp_stats out (self:t) : unit =
    Stat.pp_all out (Stat.all @@ stats self)

  let add_clause (self:t) (c:Atom.t IArray.t) : unit =
    Stat.incr self.count_clause;
    Sat_solver.add_clause_a self.solver (c:> Atom.t array) A.Proof.default

  let add_clause_l self c = add_clause self (IArray.of_list c)

  (* TODO: remove? use a special constant + micro theory instead?
  let[@inline] assume_distinct self l ~neq lit : unit =
    CC.assert_distinct (cc self) l lit ~neq
     *)

  let check_model (_s:t) : unit =
    Log.debug 1 "(smt.solver.check-model)";
    (* TODO
    Sat_solver.check_model s.solver
    *)
    ()

  let solve ?(on_exit=[]) ?(check=true) ?(on_progress=fun _ -> ())
      ~assumptions (self:t) : res =
    let do_on_exit () =
      List.iter (fun f->f()) on_exit;
    in
    self.si.on_progress <- (fun () -> on_progress self);
    let r = Sat_solver.solve ~assumptions (solver self) in
    Stat.incr self.count_solve;
    match r with
    | Sat_solver.Sat st ->
      Log.debugf 1 (fun k->k "SAT");
      let _lits f = st.iter_trail f (fun _ -> ()) in
      let m =
        Model.empty (* TODO Theory_combine.mk_model (th_combine self) lits *)
      in
      do_on_exit ();
      Sat m
    | Sat_solver.Unsat us ->
      let proof =
        try
          let pr = us.get_proof () in
          if check then Sat_solver.Proof.check pr;
          Some pr
        with Msat.Solver_intf.No_proof -> None
      in
      let unsat_core = lazy (us.Msat.unsat_assumptions ()) in
      do_on_exit ();
      Unsat {proof; unsat_core}

  let mk_theory (type st)
      ~name ~create_and_setup
      ?(push_level=fun _ -> ()) ?(pop_levels=fun _ _ -> ())
      () : theory =
    let module Th = struct
      type t = st
      let name = name
      let create_and_setup = create_and_setup
      let push_level = push_level
      let pop_levels = pop_levels
    end in
    (module Th : THEORY)
end
