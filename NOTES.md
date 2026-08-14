# Altium DelphiScript API notes

Findings from building this script against Altium Designer 26.4.1. Each one below cost a
failed run, so they are recorded rather than rediscovered.

## The verification rule

**Searching a DLL for a bare token proves nothing.** `FileName`, `X`, `Angle`, `Mirror` and
`XLocation` all exist somewhere in a 100 MB binary belonging to *other* classes. Treating
"the string is present" as proof produced four consecutive wrong answers.

What actually works:

1. Dump the string **neighbourhood around the class name** (e.g. `TPcbEmbeddedBoard`) — Delphi
   lays a class's property names out contiguously with its `GetState_`/`SetState_` accessors.
2. `SetState_<Prop>` present means writable. `GetState_` alone means **read-only**. No
   accessor at all means it is probably not scriptable.
3. **But** internal accessor names are a different namespace from the scripting interface.
   `TPcbText` has `String`/`LineWidth` where `IPCB_Text` exposes `Text`/`Width`;
   `TPcbEmbeddedBoard` has `SetState_Mirror` yet `Mirror` is unreachable from DelphiScript.
4. So the DLL can *rule things out*, but only a **probe script** confirms. A throwaway probe
   that sets one property per step, with a `ShowMessage` before each, settles in one run what
   binary inspection repeatedly got wrong.

A useful discriminator: check whether the identifier appears in `ScriptingSystem.dll`, and
compare against names known to work. `SetupRouteToolPathLayer` is absent there while every
working property is present — which correctly predicted it was unusable.

**Prefer a process call over a method call** where one exists. `RunProcess` takes strings, so a
wrong guess fails at run time with a message. A wrong property name or arity is a *compile*
error, and DelphiScript then drops the entire unit from the Run Script list with no error
shown. `Try/Except` cannot catch that.

## Embedded board array

One `IPCB_EmbeddedBoard` carries the **whole array** — not one object per instance.

```pascal
EB.DocumentPath := Path;                    // NOT FileName (read-only) or PCBFileName
EB.OriginMode   := eOriginMode_BottomLeft;  // NOT eEmbeddedBoardOriginMode_*
EB.ColCount     := Cols;
EB.RowCount     := Rows;
EB.ColSpacing   := PitchX;                  // pitch, not gap
EB.RowSpacing   := PitchY;
RegObj(Panel, EB);
EB.MoveToXY(OX, OY);                        // position is NOT a property
```

Not usable on this object: `FileName`, `X`, `Y`, `XLocation`, `YLocation`, `Angle`, `Mirror`.
`MoveToXY` lives in the generic primitive-operations block with `MoveByXY` / `FreeRotate`, so
every primitive inherits it.

## Declaring a Double does not make the value one

DelphiScript is variant-typed. A variable declared `Double` holds whatever subtype was last
assigned to it, so this silently does **integer** arithmetic and overflows:

```pascal
Var dx : Double;
...
dx  := X2 - X1;             // integer difference -> integer subtype
Len := Sqrt(dx * dx + ...); // integer multiply -> overflow -> garbage
```

A 27 mm edge is ~10,900,000 internal units and its square is 1.2e14, far past 32-bit. Force the
subtype at the boundary:

```pascal
dx := (X2 - X1) * 1.0;      // now genuinely floating point
```

This is nasty because nothing errors. Lengths come out ~360x too small, offsets land hundreds
of millimetres away, tracks get drawn off-panel, and the layer just looks empty — while any
code path that stays in integers (drilled hole positions, bounding boxes) keeps working
perfectly, which makes the geometry look selectively broken.

Diagnosing it needed a probe printing intermediate values: the signed area was correct
(it had `* 1.0` in it) while edge lengths from the same vertices were nonsense. That
inconsistency is the tell.

## Records are returned by value

`Board.BoardOutline.Segments[i]` returns a `TPolySegment` **by value**. So this compiles
cleanly and silently does nothing:

```pascal
Board.BoardOutline.Segments[0].vx := X;      // edits a discarded temporary
```

Read into a local, modify, write back:

```pascal
Seg := Board.BoardOutline.Segments[0];
Seg.Kind := ePolySegmentLine;
Seg.vx   := X;
Seg.vy   := Y;
Board.BoardOutline.Segments[0] := Seg;
```

This is why a board shape can appear to ignore every coordinate you set.

## Creating and modifying

New PCB document — `ObjectKind=PCB` is **wrong**, it opens a file browser, because `OpenObject`
means "open an existing object". There is no `New*` command in that server:

```pascal
ResetParameters;
AddStringParameter('ObjectKind', 'NewAnything');
AddStringParameter('Kind',       'DefaultPcb');   // token is DefaultPcb, not PCB
RunProcess('WorkspaceManager:OpenObject');
```

**Creating and modifying take different messages.** New objects get `PCBM_BoardRegisteration`.
Changing an object that already exists — such as the board outline on a new PCB — must be
bracketed, or the change never reaches the screen:

```pascal
PCBServer.SendMessageToRobots(Obj.I_ObjectAddress, c_Broadcast,
                              PCBM_BeginModify, c_NoEventData);
// ...modify...
PCBServer.SendMessageToRobots(Obj.I_ObjectAddress, c_Broadcast,
                              PCBM_EndModify, c_NoEventData);
```

## Mechanical layer type

`MLayer.Kind` is writable and takes `TMechanicalLayerKind` (`mlRouteToolPath`, `mlVCut`,
`mlDimensions`, …). Altium's own `SetupRouteToolPathLayer()` exists in `Advpcb.dll` but is
absent from `ScriptingSystem.dll`, so it cannot be called from script. The layer object's
visible property list does not mention `Kind` either — only a probe confirmed it.

## Not scriptable

`SheetX` / `SheetY` / `SheetWidth` / `SheetHeight` / `ShowSheet` belong to `TPCBSheet`, a
separate object — not to `IPCB_Board`. Nothing sheet-related has *any* `GetState_`/`SetState_`
accessor, the signature of something not exposed to scripting. No spelling would have worked:

```pascal
RunProcess('PCB:AutoMoveSheet');   // Design > Board Shape > Auto-Position Sheet
```

The relative origin marker is the same story — no `XOrigin`/`YOrigin` anywhere, and
`PCB:SetOrigin` is the interactive click-a-point command.

## Forms

Do not put a VCL class type in any signature — a helper like
`Function MkGroup(P : TWinControl) : TGroupBox` fails to parse, and a parse failure removes the
whole unit from the Run Script list with no error. Build controls inline instead, and give
buttons a `ModalResult` rather than binding `OnClick`, so no event handler is needed.

Label positions are font- and DPI-dependent; hardcoded pixel columns that look right at 96 dpi
will have edit boxes sitting on top of labels elsewhere. Leave generous clearance.

## Event handlers do not work

Greying out the mouse-bite fields when V-cut is picked needs a handler on the method combo, so
this was tried:

```pascal
Procedure MethodChanged(Sender : TObject);
...
CoMethod.OnChange := MethodChanged;
MethodChanged(Nil);          // <- "invalid procedure usage" at run time
```

The assignment parses and the unit still loads — it fails when the procedure is used, so this
one surfaces as a run-time error rather than a vanished script. Treat handler procedures as
unavailable.

**The way round it is to not need one.** Ask anything the dialog must react to *before* the
dialog is built, on a small form whose buttons carry a `ModalResult`, then assemble the dialog
around the answer. That hides the irrelevant settings outright instead of greying them, and
it costs one extra click.

The knock-on: a control that is not created cannot be read. Whatever the build routine reads
from those controls has to be defaulted first and read inside the branch, or it is an access
violation rather than a quiet zero.

## Locale

`StrToFloat` follows the Windows decimal separator, so on a comma-decimal locale a typed `0.2`
throws or misparses. `ParseNum` here is hand-rolled, accepts both `.` and `,`, and ignores the
system setting entirely.

## Set only what you need

Several failures came from assigning a property the value it *already had* — `Angle := 0`,
`Mirror := False`, `Mode := ePadMode_Simple`. None did any work; all three broke the script.
Write only properties that change something.
