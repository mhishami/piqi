(*pp camlp4o -I $PIQI_ROOT/camlp4 pa_labelscope.cmo pa_openin.cmo *)
(*
   Copyright 2009, 2010 Anton Lavrik

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)


(*
 * Typefull generator generator for encoding piq data into wire (Protocol
 * Buffers wire) format.
 *)

open Piqi_common
open Iolist


(* reuse several functions *)
open Piqic_ocaml_types


module W = Piqi_wire


(* XXX: move to Piqic_common/Piqi_wire? *)
let gen_code = function
  | None -> assert false
  | Some code -> ios (Int32.to_string code)
  (*
  | Some code -> ios (string_of_int code)
  *)


let gen_ocaml_type_name t ot =
  gen_piqtype t ot


let gen_parent x =
  try 
    match get_parent x with
      | `import x -> (* imported name *)
          let ocaml_modname = some_of x.Import#ocaml_name in
          ios ocaml_modname ^^ ios "."
      | _ -> iol []
  with _ -> iol [] (* NOTE, FIXME: during boot parent is not assigned *)


let rec gen_gen_type ocaml_type wire_type x =
  match x with
    | `any ->
        if !top_modname = "Piqtype"
        then ios "(fun code x -> gen_any code x)"
        else ios "(fun code x -> Piqtype.gen_any code x)"
    | (#T.piqdef as x) ->
        let modname = gen_parent x in
        modname ^^ ios "gen_" ^^ ios (piqdef_mlname x)
    | _ -> (* gen generators for built-in types *)
        iol [
          gen_cc "(reference ";
          ios "Piqirun_gen.";
          ios (gen_ocaml_type_name x ocaml_type);
          ios "_to_";
          ios (W.get_wire_type_name x wire_type);
          gen_cc ")";
        ]

and gen_gen_typeref ?ocaml_type ?wire_type t =
  gen_gen_type ocaml_type wire_type (piqtype t)


let gen_mode f =
  match f.F#mode with
    | `required -> "req"
    | `optional when f.F#default <> None -> "req" (* optional + default *)
    | `optional -> "opt"
    | `repeated -> "rep"


let gen_field rname f =
  let open Field in
  let fname = mlname_of_field f in
  let ffname = (* fully-qualified field name *)
    iod "." [ios "x"; ios rname; ios fname]
  in 
  let mode = gen_mode f in
  let fgen =
    match f.typeref with
      | Some typeref ->
          (* field generation code *)
          iod " "
            [ 
              ios "Piqirun_gen.gen_" ^^ ios mode ^^ ios "_field";
                gen_code f.code;
                gen_gen_typeref typeref;
                ffname
            ]
      | None ->
          (* flag generation code *)
          iod " " [
            gen_cc "(refer x;";
            ios "Piqirun_gen.gen_bool"; gen_code f.code; ffname;
            gen_cc ")";
          ]
  in (fname, fgen)


(* preorder fields by their field's codes *)
let order_fields fields =
    List.sort
      (fun a b ->
        match a.F#code, b.F#code with
          | Some a, Some b -> Int32.to_int (Int32.sub a b)
          (*
          | Some a, Some b -> a - b
          *)
          | _ -> assert false) fields


let gen_record r =
  (* fully-qualified capitalized record name *)
  let rname = capitalize (some_of r.R#ocaml_name) in
  (* preorder fields by their field's codes *)
  let fields = order_fields r.R#field in
  let fgens = (* field generators list *)
    List.map (gen_field rname) fields
  in
  (* field names *)
  let fnames, _ = List.split fgens in

  let esc x = ios "_" ^^ ios x in

  (* field generator code *)
  let fgens_code = List.map
    (fun (name, gen) -> iol [ ios "let "; esc name; ios " = "; gen ])
    fgens
  in (* gen_<record-name> function delcaration *)
  iod " "
    [
      ios "gen_" ^^ ios (some_of r.R#ocaml_name); ios "code x =";
        gen_cc "refer x;";
        iod " in " fgens_code;
        ios "in";
        ios "Piqirun_gen.gen_record code"; 
        ios "["; iod ";" (List.map esc fnames); ios "]";
    ]


let gen_const c =
  let open Option in
  iod " " [
    ios "|"; gen_const_name (some_of c.ocaml_name); ios "->";
      ios "Piqirun_gen.gen_varint32 code";
      gen_code c.code ^^ ios "l"; (* ocaml int32 literal *)
  ]


let gen_enum e =
  let open Enum in
  let consts = List.map gen_const e.option in
  iod " "
    [
      ios "gen_" ^^ ios (some_of e.ocaml_name);
      ios "code x =";
        gen_cc "refer x;";
        ios "match x with";
        iol consts;
    ]


let rec gen_option o =
  let open Option in
  match o.ocaml_name, o.typeref with
    | Some mln, None -> (* gen true *)
        iod " " [
          ios "|"; gen_pvar_name mln; ios "->";
            gen_cc "refer x;";
            ios "Piqirun_gen.gen_bool"; gen_code o.code; ios "true";
        ]
    | None, Some ((`variant _) as t) | None, Some ((`enum _) as t) -> (* XXX *)
        iod " " [
          ios "| (#" ^^ ios (piqdef_mlname t); ios " as x) ->";
            gen_gen_typeref t; gen_code o.code; ios "x";
        ]
    | _, Some t ->
        let mln = mlname_of_option o in
        iod " " [
          ios "|"; gen_pvar_name mln; ios "x ->";
            gen_gen_typeref t; gen_code o.code; ios "x";
        ]
    | None, None -> assert false


let gen_variant v =
  let open Variant in
  let options = List.map gen_option v.option in
  iod " "
    [
      ios "gen_" ^^ ios (some_of v.ocaml_name);
      ios "code (x:" ^^ ios_gen_typeref (`variant v) ^^ ios ") =";
      gen_cc "refer x;";
      ios "Piqirun_gen.gen_record code [(match x with"; iol options; ios ")]";
    ]


let gen_alias a =
  let open Alias in
  iod " " [
    ios "gen_" ^^ ios (some_of a.ocaml_name);
    ios "code x =";
      gen_gen_typeref a.typeref ?ocaml_type:a.ocaml_type ?wire_type:a.wire_type;
      ios "code x";
  ]


let gen_gen_list t =
  iol [
    gen_cc "reference ";
    ios "(Piqirun_gen.gen_list (" ^^ gen_gen_typeref t ^^ ios "))"
  ]


let gen_list l =
  let open L in
  iod " " [
    ios "gen_" ^^ ios (some_of l.ocaml_name);
    ios "code x =";
    gen_gen_list l.typeref; ios "code x";
  ]


let gen_def = function
  | `alias t -> gen_alias t
  | `record t -> gen_record t
  | `variant t -> gen_variant t
  | `enum t -> gen_enum t
  | `list t -> gen_list t


let gen_alias a = 
  let open Alias in
  if a.typeref = `any && not !depends_on_piq_any
  then []
  else [gen_alias a]


let gen_def = function
  | `alias x -> gen_alias x
  | x -> [gen_def x]


let gen_defs (defs:T.piqdef list) =
  let defs = flatmap gen_def defs in
  iod " "
    [
      gen_cc "let next_count = Piqloc.next_ocount";
      (* NOTE: providing special handling for boxed objects, since they are not
       * references and can not be uniquely identified. Moreover they can mask
       * integers which are used for enumerating objects *)
      gen_cc "let refer obj =
        let count = next_count () in
        if not (Obj.is_int (Obj.repr obj))
        then Piqloc.addref obj count";
      gen_cc "let reference f code x = refer x; f code x";
      ios "let rec"; iod " and " defs;
      ios "\n";
      (*
      ios "end\n";
      *)
    ]


let gen_piqi (piqi:T.piqi) =
  gen_defs piqi.P#resolved_piqdef