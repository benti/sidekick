(*
MSAT is free software, using the Apache license, see file LICENSE
Copyright 2014 Guillaume Bury
Copyright 2014 Simon Cruanes
*)

module type S = sig
  (** Signature for a module handling proof by resolution from sat solving traces *)

    (** {3 Type declarations} *)

  exception Insuficient_hyps
  (** Raised when a complete resolution derivation cannot be found using the current hypotheses. *)

  type atom
  type clause
  type lemma
  (** Abstract types for atoms, clauses and theoriy-specific lemmas *)

  type proof_node = {
    conclusion : clause;
    step : step;
  }
  and proof = unit -> proof_node
  and step =
    | Hypothesis
    | Lemma of lemma
    | Resolution of proof * proof * atom
  (** Lazy type for proof trees. *)

  (** {3 Resolution helpers} *)
  val to_list : clause -> atom list
  (** Returns the sorted list of atoms of a clause. *)

  val merge : atom list -> atom list -> atom list
  (** Merge two sorted atom list using a suitable comparison function. *)

  val resolve : atom list -> atom list * atom list
  (** Performs a "resolution step" on a sorted list of atoms.
      [resolve (List.merge l1 l2)] where [l1] and [l2] are sorted atom lists should return the pair
      [\[a\], l'], where [l'] is the result of the resolution of [l1] and [l2] over [a]. *)

  (** {3 Proof building functions} *)

  val has_been_proved : clause -> bool
  (** Returns [true] if the clause is part of the current proof graph. This function does not alter
      the proof graph (contrary to [is_proven]). *)

  val is_proven : clause -> bool
  (** Checks if the given clause has a derivation in the current state. Whatever the result,
      new proven clauses (including the given clause) may be added to the proof graph. In particular,
      hyptohesis and theory lemmas always have trivial derivations, and as such [is_proven c] (where [c]
      is a hypothesis or lemma) will always return [true] and add it to the proof graph. *)

  val prove : clause -> unit
  (** Same as 'learn', but works on single clauses instead of vectors. *)

  val learn : clause Vec.t -> unit
  (** Learn and build proofs for the clause in the vector. Clauses in the vector should be in the order they were learned. *)

  val assert_can_prove_unsat : clause -> unit
  (** [assert_can_prove_unsat c] tries and prove the empty clause from [c]. [c] may be a learnt clause not yet proved.
      @raise Insuficient_hyps if it is impossible. *)

  val prove_unsat : clause -> proof
  (** Given a conflict clause [c], returns a proof of the empty clause. Same as [assert_can_prove_unsat] but returns
      the proof if it succeeds.
      @raise Insuficient_hyps if it does not succeed. *)

  val unsat_core : proof -> clause list
  (** Returns the unsat_core of the given proof, i.e the lists of conclusions of all leafs of the proof. *)

  val print_dot : Format.formatter -> proof -> unit
  (** Print the given proof in dot format on the given formatter. *)

end
