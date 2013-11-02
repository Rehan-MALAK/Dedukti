
open Types

(* *** Global Options *** *)

let name                        = ref empty
let quiet                       = ref true
let export                      = ref false
let raphael                     = ref false
let color                       = ref true
let out                         = ref stdout (* for dk2mmt *)

let set_name s = 
  name := hstring s

let set_out file =
  out := open_out file

(* *** Info messages *** *)

let sprint = print_endline
let eprint = prerr_endline
let vprint str  = if not !quiet then prerr_endline (Lazy.force str)

let print_ok _ =                       
  if !color then vprint (lazy "\027[32m[DONE]\027[m")
  else vprint (lazy "[DONE]")

let error lc str = 
  let e' = if !color then "\n\027[31mERROR\027[m" else "ERROR" in
    eprint ( e' ^ " line:" ^ string_of_int (get_line lc) ^ " column:" 
             ^ string_of_int (get_column lc) ^ " " ^ str ) ; 
    exit 1 
