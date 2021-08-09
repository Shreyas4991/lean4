/-
Copyright (c) 2021 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.

Authors: Wojciech Nawrocki
-/
import Lean.Data.Lsp
import Lean.Message
import Lean.Elab.InfoTree
import Lean.PrettyPrinter
import Lean.Server.Utils
import Lean.Server.Rpc.Basic
import Lean.Widget.TaggedText
import Lean.Widget.Data
import Lean.Widget.ExprWithCtx

namespace Lean.Widget
open Lsp Server

private def mkPPContext (nCtx : NamingContext) (ctx : MessageDataContext) : PPContext := {
  env := ctx.env, mctx := ctx.mctx, lctx := ctx.lctx, opts := ctx.opts,
  currNamespace := nCtx.currNamespace, openDecls := nCtx.openDecls
}

private inductive EmbedFmt
  /- Tags denote `Info` objects. -/
  | expr (ctx : Elab.ContextInfo) (lctx : LocalContext) (infos : Std.RBMap Nat Elab.Info compare)
  | goal (ctx : Elab.ContextInfo) (lctx : LocalContext) (g : MVarId)
  /- Some messages (in particular, traces) are too costly to print eagerly. Instead, we allow
  the user to expand sub-traces interactively. -/
  | lazyTrace (nCtx : NamingContext) (ctx? : Option MessageDataContext) (cls : Name) (m : MessageData)
  /- Ignore any tags in this subtree. -/
  | ignoreTags
  deriving Inhabited

private abbrev MsgFmtM := StateT (Array EmbedFmt) IO

open MessageData in
/-- We first build a `Nat`-tagged `Format` with the most shallow tag, if any,
in every branch indexing into the array of embedded objects. -/
private partial def msgToInteractiveAux (msgData : MessageData) : IO (Format × Array EmbedFmt) :=
  go { currNamespace := Name.anonymous, openDecls := [] } none msgData #[]
where
  pushEmbed (e : EmbedFmt) : MsgFmtM Nat :=
    modifyGet fun es => (es.size, es.push e)

  withIgnoreTags (x : MsgFmtM Format) : MsgFmtM Format := do
    let fmt ← x
    let t ← pushEmbed EmbedFmt.ignoreTags
    return Format.tag t fmt

  go : NamingContext → Option MessageDataContext → MessageData → MsgFmtM Format
  | _,    _,         ofFormat fmt             => withIgnoreTags fmt
  | _,    _,         ofLevel u                => format u
  | _,    _,         ofName n                 => format n
  | nCtx, some ctx,  ofSyntax s               => withIgnoreTags (ppTerm (mkPPContext nCtx ctx) s) -- HACK: might not be a term
  | _,    none,      ofSyntax s               => withIgnoreTags s.formatStx
  | _,    none,      ofExpr e                 => format (toString e)
  | nCtx, some ctx,  ofExpr e                 => do
    let ci : Elab.ContextInfo := {
      env := ctx.env
      mctx := ctx.mctx
      fileMap := arbitrary
      options := ctx.opts
      currNamespace := nCtx.currNamespace
      openDecls := nCtx.openDecls }
    let (fmt, infos) ← ci.runMetaM ctx.lctx (ExprWithCtx.formatInfos e)
    let t ← pushEmbed <| EmbedFmt.expr ci ctx.lctx infos
    return Format.tag t fmt
  | _,    none,      ofGoal mvarId            => pure $ "goal " ++ format (mkMVar mvarId)
  | nCtx, some ctx,  ofGoal mvarId            => withIgnoreTags <| ppGoal (mkPPContext nCtx ctx) mvarId
  | nCtx, _,         withContext ctx d        => go nCtx ctx d
  | _,    ctx,       withNamingContext nCtx d => go nCtx ctx d
  | nCtx, ctx,       tagged n d               => do
    -- tagged is *almost* perfect for detecting traces
    -- expect for the following two other occurrences:
    -- src/Lean/Elab/Term.lean:454
    -- src/Lean/Elab/Tactic/Basic.lean:33
    let f ← pushEmbed <| EmbedFmt.lazyTrace nCtx ctx n d
    Format.tag f <$> go nCtx ctx d
  | nCtx, ctx,       nest n d                 => Format.nest n <$> go nCtx ctx d
  | nCtx, ctx,       compose d₁ d₂            => do let d₁ ← go nCtx ctx d₁; let d₂ ← go nCtx ctx d₂; pure $ d₁ ++ d₂
  | nCtx, ctx,       group d                  => Format.group <$> go nCtx ctx d
  | nCtx, ctx,       node ds                  => Format.nest 2 <$> ds.foldlM (fun r d => do let d ← go nCtx ctx d; pure $ r ++ Format.line ++ d) Format.nil

private partial def msgToInteractive (msgData : MessageData) : IO (TaggedText MsgEmbed) := do
  let (fmt, embeds) ← msgToInteractiveAux msgData
  let tt := TaggedText.prettyTagged fmt
  /- Here we rewrite a `TaggedText Nat` corresponding to a whole `MessageData` into one where
  the tags are `TaggedText MsgEmbed`s corresponding to embedded objects with their subtree
  empty (`text ""`). In other words, we terminate the `MsgEmbed`-tagged -tree at embedded objects
  and store the pretty-printed embed (which can itself be a `TaggedText`) in the tag. -/
  tt.rewriteM fun n subTt =>
    match embeds.get! n with
    | EmbedFmt.expr ctx lctx infos =>
      let subTt' := ExprWithCtx.tagExprInfos ctx lctx infos subTt
      TaggedText.tag (MsgEmbed.expr subTt') (TaggedText.text "")
    | EmbedFmt.goal ctx lctx g =>
      -- TODO(WN): use InteractiveGoal types here
      unreachable!
    | EmbedFmt.lazyTrace nCtx ctx? n m =>
      -- TODO(WN): TraceExplorer component
      TaggedText.tag (MsgEmbed.lazyTrace ⟨"1337"⟩) (TaggedText.text "")
    | EmbedFmt.ignoreTags => TaggedText.text subTt.stripTags

/-- Transform a Lean Message concerning the given text into an LSP Diagnostic. -/
def msgToDiagnostic (text : FileMap) (m : Message) : ReaderT RpcSession IO Diagnostic := do
  let low : Lsp.Position := text.leanPosToLspPos m.pos
  let fullHigh := text.leanPosToLspPos <| m.endPos.getD m.pos
  let high : Lsp.Position := match m.endPos with
    | some endPos =>
      /-
        Truncate messages that are more than one line long.
        This is a workaround to avoid big blocks of "red squiggly lines" on VS Code.
        TODO: should it be a parameter?
      -/
      let endPos := if endPos.line > m.pos.line then { line := m.pos.line + 1, column := 0 } else endPos
      text.leanPosToLspPos endPos
    | none        => low
  let range : Range := ⟨low, high⟩
  let fullRange : Range := ⟨low, fullHigh⟩
  let severity := match m.severity with
    | MessageSeverity.information => DiagnosticSeverity.information
    | MessageSeverity.warning     => DiagnosticSeverity.warning
    | MessageSeverity.error       => DiagnosticSeverity.error
  let source := "Lean 4"
  let tt ← msgToInteractive m.data
  let ttJson ← toJson <$> rpcEncode tt
  pure {
    range := range
    fullRange := fullRange
    severity? := severity
    source? := source
    message := InteractiveMessage.pretty tt
    taggedMsg? := ttJson
  }

def publishMessages (m : DocumentMeta) (msgLog : MessageLog) (hOut : IO.FS.Stream) (rpcSesh : RpcSession) : IO Unit := do
  let diagnostics ← msgLog.msgs.mapM (msgToDiagnostic m.text · rpcSesh)
  let diagParams : PublishDiagnosticsParams :=
    { uri := m.uri
      version? := some m.version
      diagnostics := diagnostics.toArray }
  hOut.writeLspNotification {
    method := "textDocument/publishDiagnostics"
    param := toJson diagParams
  }

end Lean.Widget
