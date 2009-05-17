(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_read_line
 * Copyright (C) 2009 Jérémie Dimino
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

open Lwt
open Lwt_text
open Lwt_term

type edition_state = Text.t * Text.t
type history = Text.t list
type prompt = Lwt_term.styled_text
type clipboard = Text.t ref

let clipboard = ref ""

exception Interrupt

(* +-----------------------------------------------------------------+
   | Completion                                                      |
   +-----------------------------------------------------------------+ *)

type completion_result =
  | No_completion
  | Complete_with of edition_state
  | Possibilities of Text.t list

type completion = edition_state -> unit Lwt.t -> completion_result Lwt.t

let common_prefix a b =
  let lena = String.length a and lenb = String.length b in
  let rec loop i =
    if i = lena || i = lenb || (a.[i] <> b.[i]) then
      String.sub a 0 i
    else
      loop (i + 1)
  in
  loop 0

let complete before word after words =
  match List.filter (fun word' -> Text.starts_with word' word) words with
    | [] ->
        No_completion
    | [word] ->
        Complete_with(before ^ word ^ " ", after)
    | word :: words ->
        let common_prefix = List.fold_left common_prefix word words in
        if String.length common_prefix > String.length word then
          Complete_with(before ^ common_prefix, after)
        else
          Possibilities(List.sort compare (word :: words))

(* +-----------------------------------------------------------------+
   | Commands                                                        |
   +-----------------------------------------------------------------+ *)

module Command =
struct

  type t =
    | Nop
    | Char of Text.t
    | Backward_delete_char
    | Forward_delete_char
    | Beginning_of_line
    | End_of_line
    | Complete
    | Kill_line
    | Accept_line
    | Backward_delete_word
    | Forward_delete_word
    | History_next
    | History_previous
    | Break
    | Clear_screen
    | Insert
    | Refresh
    | Backward_char
    | Forward_char
    | Set_mark
    | Yank
    | Kill_ring_save

  let to_string = function
    | Char ch ->
        Printf.sprintf "Char %S" ch
    | Nop ->
        "nop"
    | Backward_delete_char ->
        "backward-delete-char"
    | Forward_delete_char ->
        "forward-delete-char"
    | Beginning_of_line ->
        "beginning-of-line"
    | End_of_line ->
        "end-of-line"
    | Complete ->
        "complete"
    | Kill_line ->
        "kill-line"
    | Accept_line ->
        "accept-line"
    | Backward_delete_word ->
        "backward-delete-word"
    | Forward_delete_word ->
        "forward-delete-word"
    | History_next ->
        "history-next"
    | History_previous ->
        "history-previous"
    | Break ->
        "break"
    | Clear_screen ->
        "clear-screen"
    | Insert ->
        "insert"
    | Refresh ->
        "refresh"
    | Backward_char ->
        "backward-char"
    | Forward_char ->
        "forward-char"
    | Set_mark ->
        "set-mark"
    | Yank ->
        "yank"
    | Kill_ring_save ->
        "kill-ring-save"

  let of_key = function
    | Key_up -> History_previous
    | Key_down -> History_next
    | Key_left -> Backward_char
    | Key_right -> Forward_char
    | Key_enter -> Accept_line
    | Key_home -> Beginning_of_line
    | Key_end -> End_of_line
    | Key_insert -> Insert
    | Key_backspace -> Backward_delete_char
    | Key_delete -> Forward_delete_char
    | Key_tab -> Complete
    | Key_control '@' -> Set_mark
    | Key_control 'a' -> Beginning_of_line
    | Key_control 'd' -> Break
    | Key_control 'e' -> End_of_line
    | Key_control 'i' -> Complete
    | Key_control 'j' -> Accept_line
    | Key_control 'k' -> Kill_line
    | Key_control 'l' -> Clear_screen
    | Key_control 'm' -> Accept_line
    | Key_control 'n' -> Backward_char
    | Key_control 'p' -> Forward_char
    | Key_control 'r' -> Refresh
    | Key_control 'w' -> Kill_ring_save
    | Key_control 'y' -> Yank
    | Key_control '?' -> Backward_delete_char
    | Key ch when Text.length ch = 1 && Text.is_print ch -> Char ch
    | _ -> Nop
end

(* +-----------------------------------------------------------------+
   | Read-line engine                                                |
   +-----------------------------------------------------------------+ *)

module Engine =
struct
  open Command

  type selection_state = {
    sel_text : Text.t;
    sel_mark : Text.pointer;
    sel_cursor : Text.pointer;
  }

  type mode =
    | Edition of edition_state
    | Selection of selection_state

  type state = {
    mode : mode;
    history : history * history;
  }

  let init history = {
    mode = Edition("", "");
    history = (history, []);
  }

  let all_input state = match state.mode with
    | Edition(before, after) -> before ^ after
    | Selection sel -> sel.sel_text

  let edition_state state = match state.mode with
    | Edition(before, after) -> (before, after)
    | Selection sel -> (Text.chunk (Text.pointer_l sel.sel_text) sel.sel_cursor,
                        Text.chunk sel.sel_cursor (Text.pointer_r sel.sel_text))

  (* Reset the mode to the edition mode: *)
  let reset state = match state.mode with
    | Edition _ ->
        state
    | Selection sel ->
        { state with mode = Edition(Text.chunk (Text.pointer_l sel.sel_text) sel.sel_cursor,
                                    Text.chunk sel.sel_cursor (Text.pointer_r sel.sel_text)) }

  let rec update state ?(clipboard=clipboard) cmd =
    (* Helpers for updating the mode state only: *)
    let edition st = { state with mode = Edition st } and selection st = { state with mode = Selection st } in
    match state.mode with
      | Selection sel ->
          (* Change the cursor position: *)
          let maybe_set_cursor = function
            | Some(_, ptr) ->
                selection { sel with sel_cursor = ptr }
            | None ->
                state
          in

          begin match cmd with
            | Nop ->
                state

            | Forward_char ->
                maybe_set_cursor (Text.next sel.sel_cursor)

            | Backward_char ->
                maybe_set_cursor (Text.prev sel.sel_cursor)

            | Beginning_of_line ->
                selection { sel with sel_cursor =  Text.pointer_l sel.sel_text }

            | End_of_line ->
                selection { sel with sel_cursor =  Text.pointer_r sel.sel_text }

            | Kill_ring_save ->
                let a = min sel.sel_cursor sel.sel_mark and b = max sel.sel_cursor sel.sel_mark in
                clipboard := Text.chunk a b;
                edition (Text.chunk (Text.pointer_l sel.sel_text) a,
                         Text.chunk b (Text.pointer_r sel.sel_text))

            | cmd ->
                (* If the user sent another command, reset the mode to
                   edition and process the command: *)
                update (reset state) ~clipboard cmd
          end

      | Edition(before, after) ->
          begin match cmd with
            | Char ch ->
                edition (before ^ ch, after)

            | Set_mark ->
                let txt = before ^ after in
                let ptr = Text.pointer_at txt (Text.length before) in
                selection { sel_text = txt;
                            sel_mark = ptr;
                            sel_cursor = ptr }

            | Yank ->
                edition (before ^ !clipboard, after)

            | Backward_delete_char ->
                edition (Text.rchop before, after)

            | Forward_delete_char ->
                edition (before, Text.lchop after)

            | Beginning_of_line ->
                edition ("", before ^ after)

            | End_of_line ->
                edition (before ^ after, "")

            | Kill_line ->
                edition (before, "")

            | History_previous ->
                begin match state.history with
                  | ([], _) ->
                      state
                  | (line :: hist_before, hist_after) ->
                      { mode = Edition(line, "");
                        history = (hist_before, (before ^ after) :: hist_after) }
                end

            | History_next ->
                begin match state.history with
                  | (_, []) ->
                      state
                  | (hist_before, line :: hist_after) ->
                      { mode = Edition(line, "");
                        history = ((before ^ after) :: hist_before, hist_after) }
                end

            | Backward_char ->
                if before = "" then
                  state
                else
                  edition (Text.rchop before,
                           Text.get before (-1) ^ after)

            | Forward_char ->
                if after = "" then
                  state
                else
                  edition (before ^ (Text.get after 0),
                           Text.lchop after)

            | _ ->
                state
          end
end

(* +-----------------------------------------------------------------+
   | Rendering                                                       |
   +-----------------------------------------------------------------+ *)

let rec repeat f n =
  if n <= 0 then
    return ()
  else
    f () >> repeat f (n - 1)

let print_words oc cols words =
  let width = List.fold_left (fun x word -> max x (Text.length word)) 0 words + 1 in
  let columns = max 1 (cols / width) in
  let column_width = cols / columns in
  Lwt_util.fold_left
    (fun column word ->
       write oc word >>
         if column < columns then
           let len = Text.length word in
           if len < column_width then
             repeat (fun _ -> write_char oc " ") (column_width - len) >> return (column + 1)
           else
             return (column + 1)
         else
           write oc "\n" >> return 0)
    0 words >>= function
      | 0 -> return ()
      | _ -> write oc "\n"

module Terminal =
struct
  open Engine
  open Command

  type state = {
    length : int;
    (* Length in characters of the complete printed text: the prompt,
       the input before the cursor and the input after the cursor.*)
    height_before : int;
    (* The height of the complete text printed before the cursor: the
       prompt and the input before the cursor. *)
  }

  let init = { length = 0; height_before = 0 }

  (* Go-up by [n] lines then to the beginning of the line. Normally
     "\027[nF" does exactly this but for some terminal 1 need to be
     added... By the way we can relly on the fact that all terminal
     react the same way to "\027[F" which is to go to the beginning of
     the previous line: *)
  let rec beginning_of_line = function
    | 0 ->
        write_char stdout "\r"
    | 1 ->
        write_sequence stdout "\027[F"
    | n ->
        write_sequence stdout "\027[F" >> beginning_of_line (n - 1)

  (* Replace "\n" by padding to the end of line in a styled text.

     For example with 8 columns, ["toto\ntiti"] becomes ["toto titi"].

     The goal of that is to erase all previous characters after end of
     lines. *)
  let prepare_for_display columns styled_text =
    let rec loop len = function
      | [] ->
          []
      | Text text :: l ->
          let buf = Buffer.create (Text.length text) in
          let len = Text.fold
            (fun ch len -> match ch with
               | "\n" ->
                   let padding = columns - (len mod columns) in
                   Buffer.add_string buf (String.make padding ' ');
                   len + padding
               | ch ->
                   Buffer.add_string buf ch;
                   len + 1) text len in
          Text(Buffer.contents buf) :: loop len l
      | style :: l ->
          style :: loop len l
    in
    loop 0 styled_text

  (* Compute the number of row taken by a text given a number of
     columns: *)
  let compute_height columns len =
    if len = 0 then
      0
    else
      (len - 1) / columns

  (* Render the current state on the terminal, and returns the new
     terminal rendering state: *)
  let draw ?(map_text=fun x -> x) render_state engine_state prompt =
    (* Text before and after the cursor, according to the current mode: *)
    let before, after = match engine_state.mode with
      | Edition(before, after) -> ([Text(map_text before)], [Text(map_text after)])
      | Selection sel ->
          let a = min sel.sel_cursor sel.sel_mark and b = max sel.sel_cursor sel.sel_mark in
          let part_before = [Text(map_text (Text.chunk (Text.pointer_l sel.sel_text) a))]
          and part_selected = [Underlined; Text(map_text (Text.chunk a b)); Reset]
          and part_after = [Text(map_text (Text.chunk (Text.pointer_r sel.sel_text) b))] in
          if sel.sel_cursor < sel.sel_mark then
            (part_before, part_selected @ part_after)
          else
            (part_before @ part_selected, part_after)
    in

    let columns = Lwt_term.columns () in

    (* All the text printed before the cursor: *)
    let printed_before = prepare_for_display columns (prompt @ [Reset] @ before) in

    (* The total printed text: *)
    let printed_total = prepare_for_display columns (prompt @ [Reset] @ before @ after) in

    (* The new rendering state: *)
    let new_render_state = {
      height_before = compute_height columns (styled_length printed_before);
      length = styled_length printed_total;
    } in

    (* The total printed text with any needed spaces after to erase all
       previous text: *)
    let printed_total_erase = printed_total @ [Text(String.make (max 0 (render_state.length - styled_length printed_total)) ' ')] in

    (* Go back by the number of rows of the previous text: *)
    beginning_of_line render_state.height_before

    (* Prints and erase everything: *)
    >> printc printed_total_erase

    (* Go back again to the beginning of printed text: *)
    >> beginning_of_line (compute_height columns (styled_length printed_total_erase))

    (* Prints again the text before the cursor, to put the cursor at the
       right place: *)
    >> printc printed_before

    >> begin
      (* Prints another newline to avoid having the cursor displayed at
         the end of line: *)
      if (match engine_state.mode with
            | Edition(before, after) -> Text.ends_with before "\n"
            | Selection sel -> match Text.prev sel.sel_cursor with
                | Some("\n", _) -> true
                | _ -> false) then
        printlc [] >> return { new_render_state with height_before = new_render_state.height_before + 1 }
      else
        return new_render_state
    end

  let last_draw ?(map_text=fun x -> x) render_state engine_state prompt =
    beginning_of_line render_state.height_before
    >> printlc (prepare_for_display (Lwt_term.columns ()) (prompt @ [Reset; Text(map_text(all_input engine_state))]))
end

(* +-----------------------------------------------------------------+
   | High-level functions                                            |
   +-----------------------------------------------------------------+ *)

open Command

let read_command () = read_key () >|= Command.of_key

let read_line ?(history=[]) ?(complete=fun _ _ -> return No_completion) ?(clipboard=clipboard) prompt =
  let rec process_command render_state engine_state = function
    | Clear_screen ->
        clear_screen () >> redraw Terminal.init engine_state

    | Refresh ->
        redraw render_state engine_state

    | Accept_line ->
        Terminal.last_draw render_state engine_state prompt
        >> return (Engine.all_input engine_state)

    | Break ->
        Terminal.last_draw render_state engine_state prompt
        >> fail Interrupt

    | Complete ->
        let engine_state = Engine.reset engine_state in
        let abort_completion = wait () in
        let t_complete = complete (Engine.edition_state engine_state) abort_completion
        and t_command = read_command () in
        (* Let the completion and user input run in parallel: *)
        choose [(t_complete >>= fun c -> return (`Completion c));
                (t_command >>= fun c -> return (`Command c))]
        >>= begin function
          | `Command command ->
              (* The user continued to type, drop completion: *)
              wakeup abort_completion ();
              process_command render_state engine_state command
          | `Completion No_completion ->
              t_command >>= process_command render_state engine_state
          | `Completion(Complete_with(before, after)) ->
              let engine_state = { engine_state with Engine.mode = Engine.Edition(before, after) } in
              lwt render_state = Terminal.draw render_state engine_state prompt in
              t_command >>= process_command render_state engine_state
          | `Completion(Possibilities words) ->
                write_char stdout "\n"
                >> print_words stdout (Lwt_term.columns ()) words
                >> write_char stdout "\n"
                >> (lwt render_state = Terminal.draw render_state engine_state prompt in
                    t_command >>= process_command render_state engine_state)
          end

      | cmd ->
          let new_state = Engine.update engine_state ~clipboard cmd in
          (* Do not redraw if not needed: *)
          if new_state <> engine_state then
            redraw render_state new_state
          else
            loop render_state new_state

  and redraw render_state engine_state =
    lwt render_state = Terminal.draw render_state engine_state prompt in
    loop render_state engine_state

  and loop render_state engine_state =
    read_command () >>= process_command render_state engine_state
  in
  if Lazy.force stdin_is_atty && Lazy.force stdout_is_atty then
    with_raw_mode (fun _ -> redraw Terminal.init (Engine.init history))
  else
    write stdout (strip_styles prompt) >> Lwt_text.read_line stdin

let read_password ?(clipboard=clipboard) ?(style=`text "*") prompt =
  (* Choose a mapping text function according to style: *)
  let map_text = match style with
    | `text ch -> (fun txt -> Text.map (fun _ -> ch) txt)
    | `clear -> (fun x -> x)
    | `empty -> (fun _ -> "") in
  let rec process_command render_state engine_state = function
    | Clear_screen ->
        clear_screen () >> redraw Terminal.init engine_state

    | Refresh ->
        redraw render_state engine_state

    | Accept_line ->
        Terminal.last_draw ~map_text render_state engine_state prompt
        >> return (Engine.all_input engine_state)

    | Break ->
        Terminal.last_draw ~map_text render_state engine_state prompt
        >> fail Interrupt

    | cmd ->
        let new_state = Engine.update engine_state ~clipboard cmd in
        if new_state <> engine_state then
          redraw render_state new_state
        else
          loop render_state new_state

  and redraw render_state engine_state =
    lwt render_state = Terminal.draw ~map_text render_state engine_state prompt in
    loop render_state engine_state

  and loop render_state engine_state =
    read_command () >>= process_command render_state engine_state

  in
  if not (Lazy.force stdin_is_atty && Lazy.force stdout_is_atty) then
    fail (Failure "Lwt_read_line.read_password: not running in a terminal")
  else
    with_raw_mode (fun _ ->  Lwt_stream.junk_old standard_input >> redraw Terminal.init (Engine.init []))

let read_keyword ?(history=[]) ?(case_sensitive=false) prompt keywords =
  let compare = if case_sensitive then Text.compare else Text.icompare in
  let rec assoc key = function
    | [] -> None
    | (key', value) :: l ->
        if compare key key' = 0 then
          Some value
        else
          assoc key l
  in
  let rec process_command render_state engine_state = function
    | Clear_screen ->
        clear_screen () >> redraw Terminal.init engine_state

    | Refresh ->
        redraw render_state engine_state

    | Accept_line ->
        begin match assoc (Engine.all_input engine_state) keywords with
          | Some value ->
              Terminal.last_draw render_state engine_state prompt
              >> return value
          | None ->
              loop render_state engine_state
        end

    | Break ->
        Terminal.last_draw render_state engine_state prompt
        >> fail Interrupt

    | Complete ->
        let engine_state = Engine.reset engine_state in
        let txt, _ = Engine.edition_state engine_state in
        begin match List.filter (fun (kwd, _) -> Text.starts_with kwd txt) keywords with
          | [(kwd, _)] ->
              redraw render_state { engine_state with Engine.mode = Engine.Edition(kwd, "") }
          | _ ->
              loop render_state engine_state
        end

    | cmd ->
        let new_state = Engine.update engine_state ~clipboard cmd in
        if new_state <> engine_state then
          redraw render_state new_state
        else
          loop render_state new_state

  and redraw render_state engine_state =
    lwt render_state = Terminal.draw render_state engine_state prompt in
    loop render_state engine_state

  and loop render_state engine_state =
    read_command () >>= process_command render_state engine_state
  in
  if Lazy.force stdin_is_atty && Lazy.force stdout_is_atty then
    with_raw_mode (fun _ -> redraw Terminal.init (Engine.init history))
  else
    lwt _ = write stdout (strip_styles prompt) in
    lwt txt = Lwt_text.read_line stdin in
    match assoc txt keywords with
      | Some value ->
          return value
      | None ->
          fail (Failure "Lwt_read_line.read_keyword: invalid input")

let read_yes_no ?history prompt =
  read_keyword ?history prompt [("yes", true); ("y", true); ("no", false); ("n", false)]

(* +-----------------------------------------------------------------+
   | History                                                         |
   +-----------------------------------------------------------------+ *)

let save_history name history =
  with_file ~mode:Lwt_io.output name
    (fun oc ->
       Lwt_util.iter_serial
         (fun line -> write oc line >> write_char oc "\000")
         history)

let load_line ic =
  let buf = Buffer.create 42 in
  let rec loop () =
    read_char_opt ic >>= function
      | None | Some "\000" ->
          return (`Line(Buffer.contents buf))
      | Some ch ->
          Buffer.add_string buf ch;
          loop ()
  in
  read_char_opt ic >>= function
    | None -> return `End_of_file
    | Some "\000" -> return `Empty
    | Some ch -> Buffer.add_string buf ch; loop ()

let rec load_lines ic =
  load_line ic >>= function
    | `Line line ->
        lwt lines = load_lines ic in
        return (line :: lines)
    | `Empty ->
        load_lines ic
    | `End_of_file ->
        return []

let load_history name =
  match try Some(open_file ~mode:Lwt_io.input name) with _ -> None with
    | Some ic ->
        try_lwt
          load_lines ic
        finally
          close ic
    | None ->
        return []