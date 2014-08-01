(** Optimize terms before evaluation *)

open Types

type optim_rule = term -> term option

val optimize : rules:optim_rule list -> term -> term
(** Optimize the given term *)

(** {2 Rules} *)

val common_subexpr_elim : optim_rule
(** Share common subexpressions using "let" *)
