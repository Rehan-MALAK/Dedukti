open Types

type ustate = (term*term) list (* Terms to unify *)
            * (int*term)  list (* Variable to substitute *)
            * (int*term)  list (* Substitution *)

let rec not_in (k:int) (v:int) : term -> bool = function
  | Kind | Type | GVar _ | DB _ -> true
  | Meta i                      -> (i != v+k )
  | App args                    -> List.for_all (not_in k v) args 
  | Lam (ty,te) | Pi (ty,te)    -> not_in k v ty && not_in (k+1) v te

let rec subst (lst:(int*term) list) (te:term) : term =
    match te with
      | Kind | Type | GVar _ | DB _     -> te
      | Meta n                          -> 
          ( try List.assoc n lst
            with Not_found -> failwith "Cannot unify (1)." ) (*FIXME*)
      | App args                    -> App ( List.map (subst lst) args )
      | Lam (a,b)                   -> Lam ( subst lst a , subst lst b )
      | Pi  (a,b)                   -> Pi  ( subst lst a , subst lst b )

let rec unify : ustate -> (int*term) list = function
  | ( [] , [] , s)              -> s
  | ( [] , (v,t)::b , s)        -> 
      if not_in 0 v t then
        begin
          try  
            unify ( [(t,List.assoc v s)] , b , s )
          with Not_found ->
            unify ( [] , b , (v,t)::(List.map (fun (z,te) -> (z,subst [(v,t)] te)) s) ) 
        end
      else
        failwith "Cannot unify (2)." (*FIXME*)
  | ( (t1,t2)::a , b , s )      -> 
      begin
        match Reduction.decompose_eq t1 t2 with
         | None         -> failwith "Cannot unify (3)." (*FIXME*)
         | Some lst     -> unify (a,lst@b,s)
      end

let resolve_constraints (ty:term) (lst:(term*term) list) : term =
  let s = unify (lst,[],[]) in
    subst s ty


