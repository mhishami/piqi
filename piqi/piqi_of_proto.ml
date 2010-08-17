(*pp camlp4o -I `ocamlfind query ulex` -I $PIQI_ROOT/camlp4 pa_labelscope.cmo pa_openin.cmo pa_ulex.cma *)
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


module D = Descriptor

module ProtoFileSet = D.File_descriptor_set
module ProtoFile = D.File_descriptor_proto
module ProtoMessage = D.Descriptor_proto
module ProtoField = D.Field_descriptor_proto
module ProtoEnum = D.Enum_descriptor_proto
module ProtoEnumValue = D.Enum_value_descriptor_proto 


open Piqi_common
open Iolist


(* idtable implemented as map: string -> 'a *)
module Idtable =
  struct
    module M = Map.Make(String)

    type t =
      {
        mutable names : (string * string) M.t; (* proto name -> (piqi name, file) *)
        mutable imports : string M.t; (* import file -> import name *)
        mutable package : string option; (* current package *)
        mutable file : string; (* current file *)
      }


    let empty = 
      {
        names = M.empty;
        imports = M.empty;
        package = None;
        file = "";
      }


    let enter_package idtable package file =
      idtable.package <- package;
      idtable.file <- file;
      ()


    let add_name idtable proto_name piqi_name =
      let proto_name =
        match idtable.package with
          | None -> "." ^ proto_name 
          | Some x -> "." ^ x ^ "." ^ proto_name
      in
      debug "Idtable.add_name: %s -> %s\n" proto_name piqi_name;
      let value = (piqi_name, idtable.file) in
      idtable.names <- M.add proto_name value idtable.names


    let add_import idtable file import_name =
      idtable.imports <- M.add file import_name idtable.imports


    (* find import_name by file *)
    let find_import idtable file =
      try
        let res = M.find file idtable.imports in
        Some res
      with Not_found -> None


    (* find piqi_name by proto_name *)
    let find_name idtable proto_name =
      debug "Idtable.find_name: %s\n" proto_name;
      let piqi_name, file = M.find proto_name idtable.names in
      if file = idtable.file (* current file? *)
      then
        piqi_name
      else
        let import_name = 
          match find_import idtable file with
            | Some x -> x
            | None ->
                (* basename + chop all extensions + underscores to dashes *)
                let basename = Piqi_file.basename file in
                Piqi_name.make_local_name basename
        in
        import_name ^ "/" ^ piqi_name
  end


(* command-line options *)
let paths = ref []
let flag_normalize = ref false
let flag_convert_groups = ref false


let add_path x =
  paths := x::!paths



let make_name path sep =
  match path with
    | [] -> ""
    | [x] -> x
    | _ -> String.concat sep (List.rev path)


let make_proto_name path =
  make_name path "."


let format_name n =
  if !flag_normalize
  then Piqi_pp.normalize_name n
  else underscores_to_dashes n


let make_piqi_name path =
  let name = make_name path "-" in
  format_name name


let gen_enum_value path x =
  let open ProtoEnumValue in
  let name = some_of x.name in
  let piqi_name = format_name name in
  let proto_name =
    match path with
      | [] -> iol [] (* empty -- no need for separate .proto-name *)
      | _ ->
          (* after formatting and probably normalizing name we need to convert
           * dashes back to underscores *)
          let n = dashes_to_underscores (make_piqi_name (name :: path)) in
          ios ".proto-name " ^^ ioq n
  in
  iod " " [
    ios ".option [";
      ios ".name"; ios piqi_name;
      ios ".code"; ios (Int32.to_string (some_of x.number));
      proto_name;
    ios "]"
  ]


let gen_enum ?(path=[]) x =
  let open ProtoEnum in
  let new_path = (some_of x.name) :: path in
  let name = make_piqi_name new_path in
  let consts = List.map (gen_enum_value path) x.value in
  iod "\n" [
    ios ".enum [";
      ios ".name " ^^ ios name;
      iol consts;
    ios "]"
  ]


let gen_field_label = function
  | `label_required -> iol []
  | `label_optional -> ios ".optional"
  | `label_repeated -> ios ".repeated"


(*
 * string literal parser
 *)

(*
Reference implementation from protobuf-2.3.0/src/google/protobuf/stubs/strutil.cc

  while ( *p != '\0') {
    if ( *p != '\\') {
      *d++ = *p++;
    } else {
        ...
        case 'a':  *d++ = '\a';  break;
        case 'b':  *d++ = '\b';  break;
        case 'f':  *d++ = '\f';  break;
        case 'n':  *d++ = '\n';  break;
        case 'r':  *d++ = '\r';  break;
        case 't':  *d++ = '\t';  break;
        case 'v':  *d++ = '\v';  break;
        case '\\': *d++ = '\\';  break;
        case '?':  *d++ = '\?';  break;    // \?  Who knew?
        case '\'': *d++ = '\'';  break;
        case '"':  *d++ = '\"';  break;
        case '0': case '1': case '2': case '3':  // octal digit: 1 to 3 digits
        case '4': case '5': case '6': case '7': {
          char ch = *p - '0';
          if ( IS_OCTAL_DIGIT(p[1]) )
            ch = ch * 8 + *++p - '0';
          if ( IS_OCTAL_DIGIT(p[1]) )      // safe (and easy) to do this twice
            ch = ch * 8 + *++p - '0';      // now points at last digit
          *d++ = ch;
          break;
        }
        case 'x': case 'X': {
*)


let regexp digit = ['0'-'9']
let regexp odigit = ['0'-'7']
let regexp xdigit = ['0'-'9''a'-'f''A'-'F']


let parse_string_escape = lexer
  | 'a' ->  '\007'
  | 'b' ->  '\008'
  | 'f' ->  '\012'
  | 'n' ->  '\n'
  | 'r' ->  '\r'
  | 't' ->  '\t'
  | 'v' ->  '\011'
  | '\\' -> '\\'
  | '?' ->  '?'
  | '\'' -> '\''
  | '"' ->  '"'
  | odigit odigit odigit ->
      let v = Ulexing.latin1_lexeme lexbuf in
      Char.chr (Piq_lexer.int_of_ostring v)
  | ("x" | "X") xdigit xdigit ->
      let v = Ulexing.latin1_sub_lexeme lexbuf 1 2
      in
      Char.chr (Piq_lexer.int_of_xstring v)
  | _ ->
      piqi_error "invalid string escape literal in .proto"


(* returns the list of integers representing codepoints *)
let rec parse_string_literal buf = lexer
  | '\\' ->
      let c = parse_string_escape lexbuf in
      Buffer.add_char buf c;
      parse_string_literal buf lexbuf
  | eof ->
      Buffer.contents buf
  | _ ->
      let c = Ulexing.latin1_lexeme_char lexbuf 0 in
      Buffer.add_char buf c;
      parse_string_literal buf lexbuf


let parse_string_literal s =
  let buf = Buffer.create (String.length s) in
  let lexbuf = Ulexing.from_latin1_string s in
  parse_string_literal buf lexbuf


let gen_default p_type = function
  | None -> iol []
  | Some x ->
(*
  // For numeric types, contains the original text representation of the value.
  // For booleans, "true" or "false".
  // For strings, contains the default text contents (not escaped in any way).
  // For bytes, contains the C escaped value.  All bytes >= 128 are escaped.
*)
      match some_of p_type with
        | `type_enum -> ios ".default." ^^ ios (format_name x)
        | t ->
            let value =
              match t with 
                | `type_string ->
                    let s = parse_string_literal x in
                    ioq (Piq_lexer.escape_string s)
                | `type_bytes ->
                    let s = parse_string_literal x in (* XXX *)
                    ioq (Piq_lexer.escape_binary s)
                | `type_float
                | `type_double ->
                    ios (match x with
                      | "inf" -> "0.inf"
                      | "-inf" -> "-0.inf"
                      | "nan" -> "0.nan"
                      | _ -> x)
                | _ -> ios x
            in ios ".default " ^^ value


let gen_builtin_type = function
  | `type_double -> "float64"
  | `type_float -> "float32"

  | `type_int64 -> "proto-int64"
  | `type_uint64 -> "uint64"
  | `type_fixed64 -> "uint64-fixed"
  | `type_sfixed64 -> "int64-fixed"
  | `type_sint64 -> "int64"

  | `type_int32 -> "proto-int32"
  | `type_uint32 -> "uint32"
  | `type_fixed32 -> "uint32-fixed"
  | `type_sfixed32 -> "int32-fixed"
  | `type_sint32 -> "int32"
  | `type_bool -> "bool"
  | `type_string -> "string"
  | `type_bytes -> "binary"
  | `type_group | `type_message | `type_enum -> assert false


(* proto type name ->
     | imported module ^ "/" ^ piqi name
     | local piqi name
*)
let gen_type idtable proto_name :string =
  (*
    // For message and enum types, this is the name of the type.  If the name
    // starts with a '.', it is fully-qualified.  Otherwise, C++-like scoping
    // rules are used to find the type (i.e. first the nested types within this
    // message are searched, then within the parent, on up to the root
    // namespace).
  *)  
  (* for now we support only fully-qualified names *)
  (* XXX: print an error message? *)
  assert (proto_name.[0] = '.');
  Idtable.find_name idtable proto_name


let gen_field_type idtable p_type type_name =
  (*
    // If type_name is set, this need not be set.  If both this and type_name
    // are set, this must be either TYPE_ENUM or TYPE_MESSAGE.
    optional Type type = 5;

    // For message and enum types, this is the name of the type.  If the name
    // starts with a '.', it is fully-qualified.  Otherwise, C++-like scoping
    // rules are used to find the type (i.e. first the nested types within this
    // message are searched, then within the parent, on up to the root
    // namespace).
    optional string type_name = 6;
  *)
  match p_type with
    | None | Some `type_message | Some `type_enum ->
        gen_type idtable (some_of type_name)
    | Some `type_group when !flag_convert_groups ->
        gen_type idtable (some_of type_name)
    | Some `type_group ->
        piqi_error
          ".proto file contains group definitons which are not supported; use --convert-groups option to convert groups to records"
    | Some x ->
        gen_builtin_type x


(* NOTE: path is used only for nested extensions *)
let gen_field_internals idtable ?(path=[]) x =
  let open ProtoField in
  let label = gen_field_label (some_of x.label) in
  let type_name = gen_field_type idtable x.p_type x.type_name in
  let default = gen_default x.p_type x.default_value in

  let path = (some_of x.name) :: path in
  let name = make_piqi_name path in

  (match x.options with
    | None -> ()
    | Some x ->
        if x.D.Field_options#packed = Some true
        then
          (piqi_warning
            ("proto field " ^ quote name ^
             " specifies \"packed\" encoding which is not supported by Piqi yet")
          );
  );

  iod "\n" [
      ios ".name " ^^ ios name;
      ios ".type " ^^ ios type_name;
      label;
      default;
      ios ".code " ^^ ios (Int32.to_string (some_of x.number));
  ]


(* NOTE: path is used only for nested extensions *)
let gen_field idtable ?path x =
  iod "\n" [
    ios ".field [";
    gen_field_internals idtable ?path x;
    ios "]";
  ]


(* NOTE: path is used only for nested extensions *)
let gen_extension idtable ?path x =
  let open ProtoField in
  let type_name = gen_type idtable (some_of x.extendee) in
  iod "\n" [
    ios ".extend [";
      ios ".name " ^^ ios type_name;
      gen_field idtable ?path x;
    ios "]";
  ]


let rec gen_message idtable ?(path=[]) x =
  let open ProtoMessage in
  let path = (some_of x.name) :: path in
  let name = make_piqi_name path in
  let fields = List.map (gen_field idtable) x.field in
  let record =
    iod "\n" [
      ios ".record [";
        ios ".name " ^^ ios name;
        iol fields;
      ios "]"
    ]
  in
  (* gen nested definitions *)
  let messages = List.map (gen_message idtable ~path) x.nested_type in
  let enums = List.map (gen_enum ~path) x.enum_type in
  let extensions = List.map (gen_extension idtable ~path) x.extension in
  iod "\n" [
    record;
    iod "\n" messages;
    iod "\n" enums;
    iod "\n" extensions;
  ]


let gen_modname filename =
  (* XXX: revert slashes just in case *)
  let filename = string_subst_char filename '\\' '/' in
  let modname = Piqi_file.chop_all_extensions filename in
  modname


let gen_import idtable fname =
  let import_name = 
    match Idtable.find_import idtable fname with
      | Some x -> ios ".name " ^^ ios x
      | None -> iol []
  in
  let modname = gen_modname fname in

  if not (Piqi_name.is_valid_modname modname)
  then
    piqi_error
      ("can't convert imported filename to a valid piqi module name: "
       ^ fname);

  iod " " [
    ios ".import [";
      ios ".module "; ios modname;
      import_name;
    ios "]"
  ]


let process_enum idtable ?(path=[]) x =
  let open ProtoEnum in
  begin
    let path = (some_of x.name) :: path in
    let proto_name = make_proto_name path in
    let piqi_name = make_piqi_name path in
    Idtable.add_name idtable proto_name piqi_name
  end


let rec process_message idtable ?(path=[]) x =
  let open ProtoMessage in
  begin
    let path = (some_of x.name) :: path in
    let proto_name = make_proto_name path in
    let piqi_name = make_piqi_name path in
    Idtable.add_name idtable proto_name piqi_name;
    (* process nested definitions *)
    List.iter (process_message idtable ~path) x.nested_type;
    List.iter (process_enum idtable ~path) x.enum_type;
  end


let process_proto idtable (x:ProtoFile.t) =
  let open ProtoFile in
  begin
    Idtable.enter_package idtable x.package (some_of x.name);
    List.iter (process_message idtable) x.message_type;
    List.iter (process_enum idtable) x.enum_type;
    (* XXX: what about extensions? *)
  end


let gen_local_modname filename = 
  let modname = gen_modname filename in
  let name = Piqi_name.make_local_name modname in
  let path_name = Piqi_name.get_local_name modname in
  let is_optional =
    (* import name is mandatory when modname doesn't contain a valid local name
     *)
    (name = path_name)
  in
  name, is_optional


let name_imports idtable filenames =
  let make_import_name x = function
    | 0 -> x
    | counter -> x ^ "-" ^ string_of_int counter
  in
  let aux seen_names (file, x, optional) =
    let counter =
      try
        let _, counter =
          List.find (function
            | (name, _) when name = x -> true
            | _ -> false) seen_names
        in
        let name = make_import_name x counter in
        Idtable.add_import idtable file name;
        counter + 1
      with Not_found ->
        if not optional
        then Idtable.add_import idtable file x;
        0
    in
    (x, counter) :: seen_names
  in
  let pairs =
    List.map (fun x ->
      let modname, optional = gen_local_modname x in
      x, modname, optional) filenames
  in
  ignore (List.fold_left aux [] pairs)


let gen_proto idtable (x:ProtoFile.t) =
  let open ProtoFile in
  begin
    process_proto idtable x;
    name_imports idtable x.dependency;

    let imports = List.map (gen_import idtable) x.dependency in
    let messages = List.map (gen_message idtable) x.message_type in
    let enums = List.map gen_enum x.enum_type in
    let extensions = List.map (gen_extension idtable) x.extension in
    let package =
      match x.package with
        | None -> iol []
        | Some x -> ios ".proto-package " ^^ ioq x
    in
    let code =
      iod "\n" [
        package;
        iod "\n" imports;
        iod "\n" messages;
        iod "\n" enums;
        iod "\n" extensions;
      ]
    in code
  end


let process_imported_proto idtable x =
  process_proto idtable x


let process_proto_set (x:ProtoFileSet.t) =
  let open ProtoFileSet in
  let idtable = Idtable.empty in
  let rec aux = function
    | [] -> piqi_error "input FileDescriptorSet is empty"
    | [x] -> x
    | h::t ->
        process_imported_proto idtable h;
        aux t
  in
  let proto = aux x.file in
  gen_proto idtable proto


module Main = Piqi_main
open Main


let usage = "Usage: piqi of-proto [options] <.proto file>\nOptions:"


let speclist =
  [
   "-I", Arg.String add_path,
     "<dir> add directory to the list of .proto search paths (passed to protoc)";

   "--normalize", Arg.Set flag_normalize,
     "normalize identifiers (convert CamelCase to camel-case)";

   "--convert-groups", Arg.Set flag_convert_groups,
     "convert groups to records (groups are not supported)";

   arg__leave_tmp_files;
  ]


let proto_to_wire ifile ofile =
  (* build -I parameters for protoc *)
  let paths = List.rev !paths in
  let includes =
    String.concat "" (List.map (fun x -> "-I" ^ x ^ " ") paths)
  in
  let cmd = Printf.sprintf
    "protoc %s--include_imports --descriptor_set_out=%s %s" includes ofile ifile
  in
  let res = Sys.command cmd in
  if res <> 0
  then piqi_error ("command execution failed: " ^ cmd)


let read_proto_wire ifile =
  let wireobj = Piq.open_pb ifile in
  let proto_set = D.parse_file_descriptor_set wireobj in
  proto_set


let prettyprint ch tmp_file code =
  let piqi_string = Iolist.to_string code in
  (* switch piq parser to pretty-print mode *)
  (* XXX: this way we can miss some conversion errors *)
  (* Config.pp_mode := true; *)
  let ast = Piqi.read_piqi_string tmp_file piqi_string in
  Piqi_pp.prettyprint_piqi_ast ch ast


let proto_to_piqi ifile =
  if not (Filename.check_suffix ifile ".proto")
  then piqi_error "input file name must have '.proto' extension";

  (* XXX: check file has either .proto or .piqi.proto extensions without
   * any extra leading extensions *)

  let ofile = ifile ^ ".piqi" in
  let ch = Main.open_output ofile in

  let wirefile = ifile ^ ".pb" in
  Main.add_tmp_file wirefile;

  (* convert .proto file to wire format using protoc --descriptor_set_out= *)
  proto_to_wire ifile wirefile;

  (* read .proto defintion from wire file *)
  let proto_set = read_proto_wire wirefile in

  (* convert .proto to .piqi string *)
  let code = process_proto_set proto_set in

  (* dump to a temporary file before prettyprinting for easier debugging *)
  let tmp_file = ofile ^ ".tmp.piqi" in
  if !flag_leave_tmp_files
  then
    try
      let tmp_ch = open_out tmp_file in
      Iolist.to_channel tmp_ch code;
      close_out tmp_ch
    with Sys_error s ->
      piqi_error ("error writing temporary file: " ^ s)
  else ();

  (* prettyprint the result *)
  (* XXX: check the resulting piqi specification to detect conversion errors? *)
  prettyprint ch tmp_file code


let run () =
  Main.parse_args ~usage ~speclist ();
  proto_to_piqi !ifile

 
let _ =
  Main.register_command run "of-proto" "convert %.proto to %.proto.piqi"
