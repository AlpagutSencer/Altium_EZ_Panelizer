{..............................................................................}
{  Altium_Ez_Panelizer.pas                                    v2.0            }
{                                                                              }
{  Builds a depanelisable PCB panel from a source .PcbDoc, by either method:   }
{                                                                              }
{    V-CUT       straight scores along butted board edges                      }
{    MOUSE BITES router path around each board outline, spliced at tabs,       }
{                with perforations so the tabs snap off                        }
{                                                                              }
{  Either way you also get:                                                    }
{                                                                              }
{    - one Embedded Board Array object (Cols x Rows, live link to the source)  }
{    - a rectangular panel outline with breakaway rails                        }
{    - optional tooling holes, fiducials, title text and dimensions            }
{                                                                              }
{  RUN:  open this file (File > Open...) and use Run Script, or open           }
{        Altium_Ez_Panelizer.PrjScr as a project.                              }
{        Entry point: RunEzPanelizer                                           }
{                                                                              }
{  The dialogs are built inline and every button carries a ModalResult, so the }
{  script has no event handlers at all. That is deliberate - DelphiScript will }
{  not work with handler procedures the way Delphi does (see AskMethod), and a }
{  wrong signature drops the whole unit from the Run Script list with no error }
{  shown. Anything that has to react to a choice is asked before it is built.  }
{                                                                              }
{  METHOD NOTES                                                                }
{    V-cut: a straight blade cut, so it must run clear across the panel. With  }
{    a gap, each interior boundary is scored twice - once per board edge.      }
{                                                                              }
{    Mouse bites: the router traces each board's ACTUAL outline, so notches    }
{    and cutouts are followed. The path is the cutter CENTRELINE, half a bit   }
{    outside the outline, and the layer is typed Route Tool Path. Perforations }
{    go on the board edge, and optionally on the far wall of the kerf too, so  }
{    the tab breaks flush at both ends. A gap of at least one bit width is     }
{    required, including between the array and the rails.                      }
{..............................................................................}

Const
    // Panel bottom-left corner offset from the PCB origin, in mm. 0 puts the
    // corner on the absolute origin, so fab coordinates measure from there.
    // Altium's relative origin marker cannot be set from a script (no
    // XOrigin/YOrigin properties; PCB:SetOrigin is interactive), and this
    // achieves the same thing.
    cBaseOffset = 0.0;
    cMinRailFor = 1.0;    // mm, minimum rail width that will accept extras
    cMaxOutline = 512;    // max source outline vertices kept for rout tracing

Var
    // dialog controls (globals so the build routine can read them back)
    EdCols, EdRows, EdGapX, EdGapY   : TEdit;
    EdRail, EdVW, EdToolDia, EdTitle : TEdit;
    EdToolInset                      : TEdit;
    CbSideRails, CbNameLayer         : TCheckBox;
    CbTooling, CbFiducials, CbTitle  : TCheckBox;
    CbDims, CbBothSides              : TCheckBox;
    CoVLayer                         : TComboBox;
    EdTabW, EdTabs                   : TEdit;
    EdHoleDia, EdHoleCount, EdBitDia : TEdit;
    EdHolePitch, EdHoleOff           : TEdit;

    // Chosen before the settings dialog is built, because the dialog is built
    // around it: the mouse-bite controls are only created for mouse bites, so
    // nothing has to be greyed out at run time.
    GMouseBites : Boolean;

    GSrcPath         : String;
    GBoardW, GBoardH : TCoord;

    // Source board outline, stored relative to its bounding-box bottom-left so
    // an instance is just a translation. Mouse bites trace THIS, not the
    // bounding box - otherwise every concave step in the outline leaves panel
    // material still attached to the board after depanelling.
    GOutX, GOutY : Array[0..cMaxOutline] of TCoord;
    GOutN        : Integer;

    // The same outline pushed outward by half the bit - the cutter CENTRELINE.
    // The cut layer is typed Route Tool Path, so a fab routs along this line
    // rather than compensating from it; on the outline itself the kerf would
    // eat half a bit into every board.
    GRoutX, GRoutY : Array[0..cMaxOutline] of TCoord;


{..............................................................................}
{  Locale-safe number parsing.                                                 }
{  StrToFloat() follows the Windows decimal separator, so on a locale that     }
{  uses a comma ('5,0') a typed '5.0' would throw, and vice versa. This        }
{  accepts either character and never depends on the system setting.           }
{..............................................................................}
Function ParseNum(S : String; Def : Double) : Double;
Var
    i, n     : Integer;
    Neg, Any : Boolean;
    IPart    : Double;
    FPart    : Double;
    Scale    : Double;
    C        : Char;
Begin
    Result := Def;
    S := Trim(S);
    n := Length(S);
    If n = 0 Then Exit;

    Neg := False;
    i   := 1;
    If S[1] = '-' Then Begin Neg := True; i := 2; End
    Else If S[1] = '+' Then i := 2;

    IPart := 0; FPart := 0; Scale := 1; Any := False;

    While i <= n Do
    Begin
        C := S[i];
        If (C >= '0') And (C <= '9') Then
        Begin
            IPart := IPart * 10 + (Ord(C) - Ord('0'));
            Any   := True;
        End
        Else If (C = '.') Or (C = ',') Then
            Break
        Else
            Exit;                      // junk character -> keep default
        Inc(i);
    End;

    If (i <= n) And ((S[i] = '.') Or (S[i] = ',')) Then
    Begin
        Inc(i);
        While i <= n Do
        Begin
            C := S[i];
            If (C >= '0') And (C <= '9') Then
            Begin
                Scale := Scale / 10;
                FPart := FPart + (Ord(C) - Ord('0')) * Scale;
                Any   := True;
            End
            Else
                Exit;
            Inc(i);
        End;
    End;

    If Not Any Then Exit;
    Result := IPart + FPart;
    If Neg Then Result := -Result;
End;


Function ParseInt(S : String; Def : Integer) : Integer;
Begin
    Result := Round(ParseNum(S, Def));
End;


Function MM(V : Double) : TCoord;
Begin
    Result := MMsToCoord(V);
End;


Function MMStr(C : TCoord) : String;
Begin
    Result := FormatFloat('0.###', CoordToMMs(C));
End;


{..............................................................................}
{  Register a freshly created primitive with the board's undo / DRC system.    }
{..............................................................................}
Procedure RegObj(Board : IPCB_Board; Obj : IPCB_Primitive);
Begin
    Board.AddPCBObject(Obj);
    PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast,
                                  PCBM_BoardRegisteration, Obj.I_ObjectAddress);
End;


Procedure AddLine(Board : IPCB_Board; LayerID : TLayer;
                  X1, Y1, X2, Y2, W : TCoord);
Var
    Trk : IPCB_Track;
Begin
    Trk := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Trk.X1    := X1;  Trk.Y1 := Y1;
    Trk.X2    := X2;  Trk.Y2 := Y2;
    Trk.Width := W;
    Trk.Layer := LayerID;
    RegObj(Board, Trk);
End;


{  Non-plated tooling hole: pad size equals hole size, no annular ring.  }
Procedure AddToolingHole(Board : IPCB_Board; X, Y, Dia : TCoord);
Var
    Pad : IPCB_Pad;
Begin
    Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
    If Pad = Nil Then Exit;

    // Geometry, then layer, then designator. Mode is left alone - simple is
    // the default and setting it access-violates.
    Pad.X        := X;
    Pad.Y        := Y;
    Pad.TopShape := eRounded;
    Pad.TopXSize := Dia;
    Pad.TopYSize := Dia;
    Pad.HoleSize := Dia;
    Pad.Layer    := eMultiLayer;
    Pad.Name     := 'MH';

    RegObj(Board, Pad);

    // Set last and guarded: worst case the hole stays plated, which fabs
    // accept for tooling holes.
    Try
        Pad.Plated := False;
    Except
    End;
End;


{  Mouse-bite perforation. Same proven pad sequence as AddToolingHole, only  }
{  the designator differs, so the breakout holes are easy to select later.   }
Procedure AddBiteHole(Board : IPCB_Board; X, Y, Dia : TCoord);
Var
    Pad : IPCB_Pad;
Begin
    Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
    If Pad = Nil Then Exit;

    Pad.X        := X;
    Pad.Y        := Y;
    Pad.TopShape := eRounded;
    Pad.TopXSize := Dia;
    Pad.TopYSize := Dia;
    Pad.HoleSize := Dia;
    Pad.Layer    := eMultiLayer;
    Pad.Name     := 'MB';

    RegObj(Board, Pad);

    Try
        Pad.Plated := False;
    Except
    End;
End;


{..............................................................................}
{  Push the stored outline outward by D, into GRoutX / GRoutY.                 }
{                                                                              }
{  Each edge is displaced along its outward normal and consecutive displaced   }
{  edges are intersected to give the new vertex, so convex corners extend and  }
{  concave ones tuck in - a plain per-vertex push would distort the shape.     }
{  Winding is measured rather than assumed, since an outline may be drawn      }
{  either way round.                                                           }
{                                                                              }
{  Deep concave pockets narrower than the bit would need the self-intersection }
{  trimmed out; that is not done here, so a pocket tighter than the cutter     }
{  cannot be routed anyway and should be checked by eye.                       }
{..............................................................................}
Procedure OffsetPass(D : TCoord; s : Double);
Var
    i, j, h                : Integer;
    px, py, qx, qy         : Double;
    ux, uy, vx2, vy2, Len  : Double;
    ax, ay, bx, by         : Double;
    cross, t               : Double;
Begin
    For i := 0 To GOutN - 1 Do
    Begin
        // edge arriving at vertex i, and edge leaving it
        h := i - 1;  If h < 0 Then h := GOutN - 1;
        j := i + 1;  If j >= GOutN Then j := 0;

        // The * 1.0 is load-bearing. DelphiScript is variant-typed: declaring
        // a Double does not make the value one, and an integer difference
        // stays an integer, so ux * ux is evaluated in integer arithmetic and
        // overflows - a 27 mm edge is ~10,900,000 internal units and its
        // square is 1.2e14. Forcing the subtype here is what keeps every
        // length and offset below from coming out as garbage.
        ux := (GOutX[i] - GOutX[h]) * 1.0;  uy := (GOutY[i] - GOutY[h]) * 1.0;
        Len := Sqrt(ux * ux + uy * uy);
        If Len > 0 Then Begin ux := ux / Len;  uy := uy / Len; End;

        vx2 := (GOutX[j] - GOutX[i]) * 1.0;  vy2 := (GOutY[j] - GOutY[i]) * 1.0;
        Len := Sqrt(vx2 * vx2 + vy2 * vy2);
        If Len > 0 Then Begin vx2 := vx2 / Len;  vy2 := vy2 / Len; End;

        // outward normal of each edge, displaced by D
        ax := GOutX[h] + s * uy * D;    ay := GOutY[h] - s * ux * D;
        bx := GOutX[i] + s * vy2 * D;   by := GOutY[i] - s * vx2 * D;

        cross := ux * vy2 - uy * vx2;
        If Abs(cross) < 0.000001 Then
        Begin
            // edges are collinear - no corner to solve, just take the push
            GRoutX[i] := Round(GOutX[i] + s * vy2 * D);
            GRoutY[i] := Round(GOutY[i] - s * vx2 * D);
        End
        Else
        Begin
            px := bx - ax;  py := by - ay;
            t  := (px * vy2 - py * vx2) / cross;
            qx := ax + ux * t;
            qy := ay + uy * t;
            GRoutX[i] := Round(qx);
            GRoutY[i] := Round(qy);
        End;
    End;
End;


{  Offset outward, verified by result rather than by reasoning about winding.  }
{  Get the sign wrong and the path lands INSIDE the board, where it is hidden  }
{  under the copper and looks like it was never drawn - so the pass is run,    }
{  the enclosed area compared against the original, and flipped if it shrank.  }
Procedure BuildRoutOutline(D : TCoord);
Var
    i, j : Integer;
    A0, A1, s : Double;
Begin
    If GOutN < 3 Then Exit;

    // shoelace on the source outline. Doubles: TCoord products overflow.
    A0 := 0;
    For i := 0 To GOutN - 1 Do
    Begin
        j := i + 1;  If j >= GOutN Then j := 0;
        A0 := A0 + (GOutX[i] * 1.0) * GOutY[j] - (GOutX[j] * 1.0) * GOutY[i];
    End;

    If A0 >= 0 Then s := 1.0 Else s := -1.0;
    OffsetPass(D, s);

    // same measure on the result - an outward offset must enclose more
    A1 := 0;
    For i := 0 To GOutN - 1 Do
    Begin
        j := i + 1;  If j >= GOutN Then j := 0;
        A1 := A1 + (GRoutX[i] * 1.0) * GRoutY[j] - (GRoutX[j] * 1.0) * GRoutY[i];
    End;

    If Abs(A1) < Abs(A0) Then OffsetPass(D, -s);
End;


{..............................................................................}
{  One spliced router segment, in any direction.                               }
{                                                                              }
{  X1..Y2 is the cutter CENTRELINE, already pushed half a bit outside the      }
{  board. HX1..HY2 is the matching board edge, where the perforations go, so   }
{  the tab breaks flush with the board rather than half a bit proud of it.     }
{                                                                              }
{  HoleOff pushes that row off the board edge, into the cut, for boards with   }
{  copper close to the edge. It trades flushness for clearance: what is left   }
{  between the edge and the row stays on the board as a stub.                  }
{                                                                              }
{  BothSides repeats the row on the far wall of the kerf, inset by the same    }
{  HoleOff, so the tab lets go of the panel webbing as cleanly as of the board.}
{                                                                              }
{  Tabs are placed at the same fractional positions along both, so path and    }
{  perforations line up even though the offset corner makes them differ        }
{  slightly in length.                                                         }
{                                                                              }
{  Segments too short to hold a tab are routed solid - that is what keeps the  }
{  little edges of a notch from each collecting their own tabs.                }
{..............................................................................}
Procedure AddRoutSegment(Board : IPCB_Board; CutLayer : TLayer;
                         X1, Y1, X2, Y2 : TCoord;
                         HX1, HY1, HX2, HY2 : TCoord;
                         Tabs, HoleCount : Integer;
                         TabW, BitW, HoleDia, HolePitch, HoleOff : TCoord;
                         BothSides : Boolean;
                         Var nHoles, nSegs : Integer);
Var
    k, h, nH          : Integer;
    HLen, Half        : Double;
    HalfSpan          : Double;
    dx, dy, dot       : Double;
    ux, uy            : Double;
    ovx, ovy          : Double;
    PerpLen, nx, ny   : Double;
    o1, o2            : Double;
    sStart, sEnd      : Double;
    c, s, e, p        : Double;
    ax, ay            : TCoord;
    bx, by            : TCoord;
Begin
    // Everything is parameterised along the BOARD EDGE, and the path is that
    // parameter plus a fixed perpendicular offset. Measuring the path by its
    // own length instead would misplace the tabs: offsetting lengthens an edge
    // at a convex corner and shortens it at a concave one, so the same
    // fraction lands somewhere different on each, and the drill row drifts out
    // of its gap by a different amount on every side.
    //
    // The * 1.0 is load-bearing - see BuildRoutOutline. Declaring a Double is
    // not enough; DelphiScript keeps the integer subtype and would overflow.
    dx := (HX2 - HX1) * 1.0;
    dy := (HY2 - HY1) * 1.0;
    HLen := Sqrt(dx * dx + dy * dy);
    If HLen <= 0 Then Exit;

    ux := dx / HLen;
    uy := dy / HLen;

    // where the path's ends sit along the edge, and how far off it they are
    dx  := (X1 - HX1) * 1.0;
    dy  := (Y1 - HY1) * 1.0;
    dot := dx * ux + dy * uy;
    ovx := dx - dot * ux;          // pure perpendicular component
    ovy := dy - dot * uy;
    sStart := dot;

    dx := (X2 - HX1) * 1.0;
    dy := (Y2 - HY1) * 1.0;
    sEnd := dx * ux + dy * uy;

    Half := TabW / 2;

    // No room for a tab plus a little material either side - route it solid.
    If (Tabs < 1) Or (HLen < TabW * 2) Then
    Begin
        AddLine(Board, CutLayer, X1, Y1, X2, Y2, BitW);
        Inc(nSegs);
        Exit;
    End;

    // --- cutter path, interrupted at each tab ---
    s := sStart;
    For k := 0 To Tabs - 1 Do
    Begin
        c := HLen * (2 * k + 1) / (2 * Tabs);
        e := c - Half;
        If e > s Then
        Begin
            ax := HX1 + Round(ux * s + ovx);   ay := HY1 + Round(uy * s + ovy);
            bx := HX1 + Round(ux * e + ovx);   by := HY1 + Round(uy * e + ovy);
            AddLine(Board, CutLayer, ax, ay, bx, by, BitW);
            Inc(nSegs);
        End;
        s := c + Half;
    End;
    If sEnd > s Then
    Begin
        ax := HX1 + Round(ux * s + ovx);  ay := HY1 + Round(uy * s + ovy);
        AddLine(Board, CutLayer, ax, ay, X2, Y2, BitW);
        Inc(nSegs);
    End;

    // --- perforations along each tab, on the outline itself ---
    // Count and pitch describe the drill pattern; the tab width is separate and
    // says how much material is left un-routed. The row is centred in the tab,
    // so it may be narrower, leaving solid material at each end.
    //
    // The second row sits on the FAR WALL OF THE KERF, one full bit width off
    // the board edge: the centreline is half a bit out and the cut is a bit
    // wide. ovx/ovy is that half-bit perpendicular, so twice it lands on the
    // far wall. Without it the tab tears off the panel webbing wherever it
    // happens to give, leaving a nub on the rail or on the neighbour.
    //
    // Both rows are then walked toward each other by HoleOff. The perpendicular
    // is measured from ovx/ovy rather than assumed to be half of BitW, so this
    // stays right if the path is ever offset by something else.
    PerpLen := Sqrt(ovx * ovx + ovy * ovy);
    If PerpLen <= 0 Then Exit;

    nx := ovx / PerpLen;
    ny := ovy / PerpLen;

    o1 := HoleOff * 1.0;                 // near row, off the board edge
    o2 := 2 * PerpLen - o1;              // far row, same inset from the far wall

    nH := HoleCount;
    If nH < 2 Then nH := 2;
    HalfSpan := (nH - 1) * (HolePitch * 1.0) / 2;

    For k := 0 To Tabs - 1 Do
    Begin
        c := HLen * (2 * k + 1) / (2 * Tabs);   // same measure as the gap above
        For h := 0 To nH - 1 Do
        Begin
            p := c - HalfSpan + (HolePitch * 1.0) * h;

            AddBiteHole(Board, HX1 + Round(ux * p + nx * o1),
                               HY1 + Round(uy * p + ny * o1), HoleDia);
            Inc(nHoles);

            If BothSides Then
            Begin
                AddBiteHole(Board, HX1 + Round(ux * p + nx * o2),
                                   HY1 + Round(uy * p + ny * o2), HoleDia);
                Inc(nHoles);
            End;
        End;
    End;
End;


{  Fiducial: copper dot on the top layer with an oversized mask opening.  }
Procedure AddFiducial(Board : IPCB_Board; X, Y, CuDia, MaskDia : TCoord);
Var
    Pad : IPCB_Pad;
Begin
    Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
    If Pad = Nil Then Exit;

    Pad.X        := X;
    Pad.Y        := Y;
    Pad.TopShape := eRounded;
    Pad.TopXSize := CuDia;
    Pad.TopYSize := CuDia;
    Pad.HoleSize := 0;
    Pad.Layer    := eTopLayer;
    Pad.Name     := 'FID';

    RegObj(Board, Pad);

    // SolderMaskExpansion is deliberately not set - it access-violates inside
    // the interpreter, which Try/Except does not reliably catch. The mask
    // opening therefore follows the board rule rather than MaskDia. If it is
    // too tight, add a Mask Expansion rule scoped to pads named 'FID'.
    // MaskDia stays a parameter so the intended value is still documented.
End;


Procedure AddText(Board : IPCB_Board; LayerID : TLayer;
                  X, Y : TCoord; S : String; H, W : TCoord);
Var
    Txt : IPCB_Text;
Begin
    Txt := PCBServer.PCBObjectFactory(eTextObject, eNoDimension, eCreate_Default);
    Txt.XLocation  := X;
    Txt.YLocation  := Y;
    Txt.Layer      := LayerID;
    Txt.Text       := S;
    Txt.Size       := H;
    Txt.Width      := W;
    Txt.UseTTFonts := False;
    // No Rotation: text uses Angle, and unrotated is the default anyway.
    RegObj(Board, Txt);
End;


{..............................................................................}
{  Dimension annotations.                                                      }
{                                                                              }
{  Drawn from tracks and text rather than IPCB_Dimension objects. The real     }
{  dimension class needs reference points wired up and is easy to get wrong;   }
{  AddLine and AddText are already proven working here, so the annotation is   }
{  built from those. It is a drawing aid, not a live measurement - it will NOT }
{  update if you move things afterwards.                                       }
{..............................................................................}
Procedure AddDimH(Board : IPCB_Board; LayerID : TLayer;
                  X1, X2, Y, W : TCoord; Caption : String);
Var
    T, H : TCoord;
Begin
    T := MM(1.2);
    H := T Div 2;

    // witness stubs at each end
    AddLine(Board, LayerID, X1, Y - T, X1, Y + T, W);
    AddLine(Board, LayerID, X2, Y - T, X2, Y + T, W);

    // dimension line
    AddLine(Board, LayerID, X1, Y, X2, Y, W);

    // arrow ticks
    AddLine(Board, LayerID, X1, Y, X1 + T, Y + H, W);
    AddLine(Board, LayerID, X1, Y, X1 + T, Y - H, W);
    AddLine(Board, LayerID, X2, Y, X2 - T, Y + H, W);
    AddLine(Board, LayerID, X2, Y, X2 - T, Y - H, W);

    AddText(Board, LayerID, (X1 + X2) Div 2 - MM(6.0), Y + MM(1.0),
            Caption, MM(1.5), MM(0.2));
End;


Procedure AddDimV(Board : IPCB_Board; LayerID : TLayer;
                  Y1, Y2, X, W : TCoord; Caption : String);
Var
    T, H : TCoord;
Begin
    T := MM(1.2);
    H := T Div 2;

    AddLine(Board, LayerID, X - T, Y1, X + T, Y1, W);
    AddLine(Board, LayerID, X - T, Y2, X + T, Y2, W);

    AddLine(Board, LayerID, X, Y1, X, Y2, W);

    AddLine(Board, LayerID, X, Y1, X + H, Y1 + T, W);
    AddLine(Board, LayerID, X, Y1, X - H, Y1 + T, W);
    AddLine(Board, LayerID, X, Y2, X + H, Y2 - T, W);
    AddLine(Board, LayerID, X, Y2, X - H, Y2 - T, W);

    // Caption sits horizontally beside the line; text rotation is not used.
    AddText(Board, LayerID, X - MM(15.0), (Y1 + Y2) Div 2,
            Caption, MM(1.5), MM(0.2));
End;


{..............................................................................}
{  Read the bounding box of a source .PcbDoc board outline.                    }
{  Opens the document (Altium needs it loaded to expose the outline).          }
{  Arc segments are approximated by their vertex points, which is exact for    }
{  the rectangular outlines that V-cut panels require anyway.                  }
{..............................................................................}
Function ReadBoardSize(APath : String; Var W, H : TCoord) : Boolean;
Var
    Doc            : IServerDocument;
    B              : IPCB_Board;
    i, n           : Integer;
    x1, y1, x2, y2 : TCoord;
    vx, vy         : TCoord;
Begin
    Result := False;
    W := 0;  H := 0;

    If Not FileExists(APath) Then
    Begin
        ShowMessage('Source PCB not found:' + #13#10 + APath);
        Exit;
    End;

    Doc := Client.OpenDocument('PCB', APath);
    If Doc = Nil Then
    Begin
        ShowMessage('Could not open the source PCB document.');
        Exit;
    End;
    Client.ShowDocument(Doc);

    B := PCBServer.GetCurrentPCBBoard;
    If B = Nil Then
    Begin
        ShowMessage('The source document did not load as a PCB.');
        Exit;
    End;

    n := B.BoardOutline.PointCount;
    If n < 3 Then
    Begin
        ShowMessage('The source board outline has fewer than 3 vertices.');
        Exit;
    End;

    x1 :=  2000000000;  y1 :=  2000000000;
    x2 := -2000000000;  y2 := -2000000000;

    For i := 0 To n - 1 Do
    Begin
        vx := B.BoardOutline.Segments[i].vx;
        vy := B.BoardOutline.Segments[i].vy;
        If vx < x1 Then x1 := vx;
        If vy < y1 Then y1 := vy;
        If vx > x2 Then x2 := vx;
        If vy > y2 Then y2 := vy;
    End;

    W := x2 - x1;
    H := y2 - y1;

    // Keep the vertices too, relative to the bbox corner. Arc segments are
    // taken as the chord between their endpoints - exact for the rectilinear
    // outlines this matters most for, slightly inside the true edge on a
    // rounded corner.
    GOutN := n;
    If GOutN > cMaxOutline Then GOutN := cMaxOutline;
    For i := 0 To GOutN - 1 Do
    Begin
        GOutX[i] := B.BoardOutline.Segments[i].vx - x1;
        GOutY[i] := B.BoardOutline.Segments[i].vy - y1;
    End;

    Result := (W > 0) And (H > 0);
End;


{..............................................................................}
{  Main build - reads the dialog globals and generates the panel.              }
{..............................................................................}
Procedure DoBuildPanel;
Var
    Cols, Rows            : Integer;
    GapX, GapY            : TCoord;
    Rail, VW, ToolDia     : TCoord;
    SideRails             : Boolean;
    LRail, RRail          : TCoord;
    PitchX, PitchY        : TCoord;
    BoardsW, BoardsH      : TCoord;
    PanelW, PanelH        : TCoord;
    BX, BY, OX, OY        : TCoord;
    Panel                 : IPCB_Board;
    EB                    : IPCB_EmbeddedBoard;
    VLayer, DimLayer      : TLayer;
    MLayer                : IPCB_LayerObject;
    LayerNo, DimLayerNo   : Integer;
    i, nLines             : Integer;
    Mrg                   : TCoord;
    xline, yline          : TCoord;
    Inset, FidCu, FidMask : TCoord;
    DoLine                : Boolean;
    Seg                   : TPolySegment;
    MouseBites, BothSides : Boolean;
    TabW, HoleDia, HolePitch : TCoord;
    HoleOff               : TCoord;
    HoleCount             : Integer;
    BitW                  : TCoord;
    ARect                 : TCoordRect;
    ax, ay                : TCoord;
    bx0, by0              : TCoord;
    c, r, k2              : Integer;
    Tabs, nHoles          : Integer;
    ToolInset, TextX      : TCoord;
    ToolMin, ToolMax      : TCoord;
    LGap, RGap, BGap, TGap   : TCoord;
    Msg, Warn             : String;
Begin
    // ---------- 1. gather + validate input ----------
    Cols := ParseInt(EdCols.Text, 2);
    Rows := ParseInt(EdRows.Text, 3);
    If (Cols < 1) Or (Rows < 1) Then
    Begin
        ShowMessage('Columns and rows must both be at least 1.');
        Exit;
    End;

    GapX      := MM(ParseNum(EdGapX.Text, 0));
    GapY      := MM(ParseNum(EdGapY.Text, 0));
    Rail      := MM(ParseNum(EdRail.Text, 5));
    VW        := MM(ParseNum(EdVW.Text, 0.2));
    ToolDia   := MM(ParseNum(EdToolDia.Text, 3.0));
    ToolInset := MM(ParseNum(EdToolInset.Text, 2.5));
    SideRails := CbSideRails.Checked;

    // One inset, measured from BOTH edges a hole sits against - a corner hole
    // is as far down from the top as it is in from the side. It is used exactly
    // as typed; what it has to fit inside is checked below, once the rail width
    // has been validated.
    ToolMin := ToolDia Div 2 + MM(0.5);
    ToolMax := Rail - ToolDia Div 2 - MM(0.5);

    MouseBites := GMouseBites;

    // The mouse-bite controls are only created when that method was chosen, so
    // they are read inside the branch. Reading one that was never created is an
    // access violation, not a nil that quietly comes back as zero.
    TabW      := MM(5.0);   Tabs      := 2;
    HoleDia   := MM(0.5);   HoleCount := 5;
    HolePitch := MM(1.0);   HoleOff   := 0;
    BitW      := MM(2.0);   BothSides := False;

    If MouseBites Then
    Begin
        TabW       := MM(ParseNum(EdTabW.Text, 5.0));
        Tabs       := ParseInt(EdTabs.Text, 2);
        HoleDia    := MM(ParseNum(EdHoleDia.Text, 0.5));
        HoleCount  := ParseInt(EdHoleCount.Text, 5);
        HolePitch  := MM(ParseNum(EdHolePitch.Text, 1.0));
        HoleOff    := MM(ParseNum(EdHoleOff.Text, 0));
        BitW       := MM(ParseNum(EdBitDia.Text, 2.0));
        BothSides  := CbBothSides.Checked;

        If HoleOff < 0 Then HoleOff := 0;
        If Tabs < 1 Then Tabs := 1;
        If HoleCount < 2 Then HoleCount := 2;
        If BitW <= 0 Then BitW := MM(2.0);

        // Each board's cutter path sits half a bit outside its outline, so the
        // kerf occupies a full bit width off each board edge. Two neighbours
        // therefore need 2 x bit between them to leave any webbing; below that
        // the kerfs meet and the gap is simply cleared out, which still works
        // but leaves the tabs holding everything.
        If (GapX < BitW) Or (GapY < BitW) Then
        Begin
            ShowMessage('The cutter path sits half a bit outside each board, so ' +
                        'the gap has to fit the bit.' + #13#10 + #13#10 +
                        'Gap X and Gap Y must be at least the bit diameter (' +
                        MMStr(BitW) + ' mm); below ' + MMStr(2 * BitW) +
                        ' mm the two kerfs meet and no webbing is left between ' +
                        'neighbouring boards - the tabs then hold it all.' +
                        #13#10 + #13#10 +
                        'Widen the gap, use a smaller bit, or switch back to V-cut.');
            Exit;
        End;

        If HolePitch <= 0 Then HolePitch := MM(1.0);

        If HoleDia >= HolePitch Then
        Begin
            ShowMessage('Hole diameter (' + MMStr(HoleDia) + ' mm) must be less ' +
                        'than the hole pitch (' + MMStr(HolePitch) + ' mm), or ' +
                        'the holes merge into a slot instead of a perforation.');
            Exit;
        End;

        // The row is pushed off the board edge toward the cut, so past the
        // centreline it would sit in the far half of the kerf - which is what
        // the far-side row is for, not what this setting means.
        If HoleOff >= BitW Div 2 Then
        Begin
            ShowMessage('Hole offset (' + MMStr(HoleOff) + ' mm) has to stay ' +
                        'under half the bit (' + MMStr(BitW Div 2) + ' mm).' +
                        #13#10 + #13#10 +
                        'The row is pushed off the board edge into the cut, and ' +
                        'half a bit is where the cutter centreline runs; past ' +
                        'that it would be drilled in the far half of the channel.');
            Exit;
        End;

        // Both rows walk toward each other by the offset, so what matters is
        // what is left between them, not the bit alone.
        If BothSides And (HoleDia >= BitW - 2 * HoleOff) Then
        Begin
            ShowMessage('The two rows end up ' + MMStr(BitW - 2 * HoleOff) +
                        ' mm apart - the ' + MMStr(BitW) + ' mm bit less twice ' +
                        'the ' + MMStr(HoleOff) + ' mm offset - so a ' +
                        MMStr(HoleDia) + ' mm hole would run into its opposite ' +
                        'number and cut the tab through.' + #13#10 + #13#10 +
                        'Use a larger bit, a smaller hole or offset, or ' +
                        'perforate one side only.');
            Exit;
        End;

        // Between two boards, each one drills its own far row. Those rows only
        // stay distinct while there is webbing between the kerfs, which needs
        // more than 2 x bit of gap. At exactly 2 x bit both land on the same
        // line and the pads are drilled twice; below it they interleave inside
        // a shared tab. Neither is wrong at the fab, but it is not what the
        // setting looks like it does, so say so rather than quietly doubling up.
        If BothSides And (Cols + Rows > 2) And
           ((GapX <= 2 * BitW) Or (GapY <= 2 * BitW)) Then
            If Not ConfirmNoYes('Perforating both sides drills a row on the far ' +
                                'wall of the cut, one bit width (' + MMStr(BitW) +
                                ' mm) off the board edge.' + #13#10 + #13#10 +
                                'Between two boards that row only stands on its ' +
                                'own where webbing is left, which needs a gap ' +
                                'wider than ' + MMStr(2 * BitW) + ' mm. At your ' +
                                'gap the two boards'' far rows fall on the same ' +
                                'line or cross inside a shared tab, so those ' +
                                'holes get drilled twice.' + #13#10 + #13#10 +
                                'Widen the gap past ' + MMStr(2 * BitW) +
                                ' mm, or perforate the board edge only.' +
                                #13#10 + #13#10 + 'Continue anyway?') Then Exit;

        // The drill row is centred in the tab, so it has to fit inside it.
        If (HoleCount - 1) * HolePitch > TabW Then
        Begin
            ShowMessage(IntToStr(HoleCount) + ' holes at ' + MMStr(HolePitch) +
                        ' mm pitch span ' + MMStr((HoleCount - 1) * HolePitch) +
                        ' mm, which does not fit in a ' + MMStr(TabW) +
                        ' mm tab.' + #13#10 + #13#10 +
                        'Widen the tab, reduce the pitch, or use fewer holes.');
            Exit;
        End;
    End;

    If Rail <= 0 Then
    Begin
        ShowMessage('Rail width must be greater than 0.');
        Exit;
    End;

    // A gap is legitimate - each interior boundary gets two scores and the
    // strip between them drops out as waste. Only warn when that strip is too
    // narrow to survive handling or to give the blade room to clear.
    If (Not MouseBites) And
       (((GapX > 0) And (GapX < MM(1.5))) Or ((GapY > 0) And (GapY < MM(1.5)))) Then
        If Not ConfirmNoYes('With a gap, each interior boundary is scored twice - ' +
                            'once per board edge - and the strip between them drops ' +
                            'out as waste.' + #13#10 + #13#10 +
                            'The strip you have specified is under 1.5 mm wide. That ' +
                            'is fragile to handle and leaves the blade little room to ' +
                            'clear, so it may break up during depanelling.' +
                            #13#10 + #13#10 +
                            'Use gap = 0 for true butt-jointed V-cut, or widen it.' +
                            #13#10 + #13#10 + 'Continue anyway?') Then Exit;

    If CbTooling.Checked And (ToolDia >= Rail) Then
    Begin
        ShowMessage('Tooling hole diameter (' + MMStr(ToolDia) +
                    ' mm) must be smaller than the rail width (' +
                    MMStr(Rail) + ' mm).');
        Exit;
    End;

    // The inset is honoured as typed rather than quietly pulled back to what
    // fits: a panel that came back with its holes somewhere other than where
    // they were asked for is worse than being told the number is impossible.
    // Both bounds name the value that would work, so the message is actionable.
    If CbTooling.Checked And (ToolInset < ToolMin) Then
    Begin
        ShowMessage('Tooling hole inset (' + MMStr(ToolInset) + ' mm) leaves under ' +
                    '0.5 mm of material between the hole and the panel edge.' +
                    #13#10 + #13#10 +
                    'With a ' + MMStr(ToolDia) + ' mm hole the smallest inset that ' +
                    'holds is ' + MMStr(ToolMin) + ' mm.');
        Exit;
    End;

    If CbTooling.Checked And (ToolInset > ToolMax) Then
    Begin
        ShowMessage('Tooling hole inset (' + MMStr(ToolInset) + ' mm) does not fit ' +
                    'across a ' + MMStr(Rail) + ' mm rail. The hole is inset the ' +
                    'same distance from both edges it faces, so this one would ' +
                    'hang off the inside of the rail and into the boards.' +
                    #13#10 + #13#10 +
                    'This rail takes up to ' + MMStr(ToolMax) + ' mm. Widen the ' +
                    'rail if you want the holes further in.');
        Exit;
    End;

    LayerNo := CoVLayer.ItemIndex + 1;
    If LayerNo < 1 Then LayerNo := 1;

    // Cleared here, not later: section 6 can already append to it.
    Warn := '';

    // ---------- 2. geometry ----------
    PitchX  := GBoardW + GapX;
    PitchY  := GBoardH + GapY;
    BoardsW := Cols * PitchX - GapX;
    BoardsH := Rows * PitchY - GapY;

    If SideRails Then Begin LRail := Rail; RRail := Rail; End
    Else              Begin LRail := 0;    RRail := 0;    End;

    // Mouse bites need a routed channel between the array and the RAILS too,
    // not just between boards - otherwise the outer boards are still solidly
    // attached and there is nothing to snap. V-cut scores through butted
    // material instead, so it needs no such channel.
    If MouseBites Then
    Begin
        BGap := GapY;
        TGap := GapY;
        If SideRails Then Begin LGap := GapX; RGap := GapX; End
        Else              Begin LGap := 0;    RGap := 0;    End;
    End
    Else
    Begin
        LGap := 0;  RGap := 0;  BGap := 0;  TGap := 0;
    End;

    PanelW := LRail + LGap + BoardsW + RGap + RRail;
    PanelH := Rail  + BGap + BoardsH + TGap + Rail;

    BX := MM(cBaseOffset);
    BY := MM(cBaseOffset);
    OX := BX + LRail + LGap;
    OY := BY + Rail  + BGap;

    // ---------- 3. new PCB document ----------
    // Same command File > New > PCB uses. ObjectKind=PCB would instead pop a
    // file browser, since OpenObject means "open an existing object".
    ResetParameters;
    AddStringParameter('ObjectKind', 'NewAnything');
    AddStringParameter('Kind',       'DefaultPcb');
    RunProcess('WorkspaceManager:OpenObject');

    Panel := PCBServer.GetCurrentPCBBoard;
    If Panel = Nil Then
    Begin
        ShowMessage('Could not create the panel PCB document.');
        Exit;
    End;

    Try
        Panel.DisplayUnit := eMetric;
    Except
        // not fatal
    End;

    PCBServer.PreProcess;
    Try
        // ---------- 4. panel outline ----------
        // The outline already exists on a new PCB, so this is a modification
        // and needs the BeginModify/EndModify bracket - PCBM_BoardRegisteration
        // is for newly created objects only.
        PCBServer.SendMessageToRobots(Panel.BoardOutline.I_ObjectAddress,
                                      c_Broadcast, PCBM_BeginModify, c_NoEventData);

        Panel.BoardOutline.Invalidate;
        Panel.BoardOutline.PointCount := 4;

        // Segments[i] returns the record BY VALUE, so `Segments[i].vx := BX`
        // edits a discarded temporary - it compiles and silently does nothing.
        // Each vertex must be read into a local, modified, and written back.
        Seg := Panel.BoardOutline.Segments[0];
        Seg.Kind := ePolySegmentLine;
        Seg.vx   := BX;
        Seg.vy   := BY;
        Panel.BoardOutline.Segments[0] := Seg;

        Seg := Panel.BoardOutline.Segments[1];
        Seg.Kind := ePolySegmentLine;
        Seg.vx   := BX + PanelW;
        Seg.vy   := BY;
        Panel.BoardOutline.Segments[1] := Seg;

        Seg := Panel.BoardOutline.Segments[2];
        Seg.Kind := ePolySegmentLine;
        Seg.vx   := BX + PanelW;
        Seg.vy   := BY + PanelH;
        Panel.BoardOutline.Segments[2] := Seg;

        Seg := Panel.BoardOutline.Segments[3];
        Seg.Kind := ePolySegmentLine;
        Seg.vx   := BX;
        Seg.vy   := BY + PanelH;
        Panel.BoardOutline.Segments[3] := Seg;

        Panel.BoardOutline.Rebuild;
        Panel.BoardOutline.Validate;

        PCBServer.SendMessageToRobots(Panel.BoardOutline.I_ObjectAddress,
                                      c_Broadcast, PCBM_EndModify, c_NoEventData);

        // ---------- 5. embedded board array ----------
        // A single IPCB_EmbeddedBoard object carries the whole Cols x Rows
        // array; it is not one object per instance.
        EB := PCBServer.PCBObjectFactory(eEmbeddedBoardObject, eNoDimension,
                                         eCreate_Default);
        // Source file is DocumentPath - FileName exists but is read-only.
        EB.DocumentPath := GSrcPath;
        EB.OriginMode   := eOriginMode_BottomLeft;
        EB.ColCount     := Cols;
        EB.RowCount     := Rows;
        EB.ColSpacing   := PitchX;
        EB.RowSpacing   := PitchY;
        // Angle and Mirror are not exposed on this object by the scripting
        // interface, and both already default correctly. Use FreeRotate to
        // rotate an array later.
        RegObj(Panel, EB);

        // Position is not a property here - placement goes through the
        // primitive-level MoveToXY, after the object is on the board.
        EB.MoveToXY(OX, OY);

        // MoveToXY's anchor is not the array's bounding-box corner, so the
        // instances land offset from (OX, OY) and every downstream feature -
        // score lines, rout paths, panel outline - is then measured from the
        // wrong place. Rather than assume what eOriginMode_BottomLeft anchors
        // to, read back where the array actually is and correct by the delta,
        // so the bbox corner ends up exactly on (OX, OY).
        Try
            ARect := EB.BoundingRectangle;
            ax := ARect.x1;  If ARect.x2 < ax Then ax := ARect.x2;
            ay := ARect.y1;  If ARect.y2 < ay Then ay := ARect.y2;
            If (ax <> OX) Or (ay <> OY) Then
                EB.MoveToXY(OX + (OX - ax), OY + (OY - ay));
        Except
            Warn := Warn + #13#10 + '  - array position could not be verified';
        End;

        // ---------- 6. cut layer ----------
        VLayer := LayerUtils.MechanicalLayer(LayerNo);
        Try
            MLayer := Panel.LayerStack_V7.LayerObject_V7(VLayer);
            If MLayer <> Nil Then
            Begin
                MLayer.MechanicalLayerEnabled := True;
                If CbNameLayer.Checked Then
                    If MouseBites Then MLayer.Name := 'Routing'
                    Else               MLayer.Name := 'V-Cut';

                // MLayer.Kind takes TMechanicalLayerKind. Altium's own
                // SetupRouteToolPathLayer() is not script-visible; this is.
                Try
                    If MouseBites Then MLayer.Kind := mlRouteToolPath
                    Else               MLayer.Kind := mlVCut;
                Except
                    Warn := Warn + #13#10 + '  - cut layer type not set';
                End;
            End;
        Except
            // layer stays as-is; the lines are still drawn
        End;

        // ---------- 7. separation: V-cut scores, or routed channels ----------
        nLines := 0;
        nHoles := 0;

        If Not MouseBites Then
        Begin

        // A score must run along a BOARD EDGE - the blade separates material at
        // the line it cuts. With a gap, an interior boundary therefore needs
        // TWO scores, one per adjacent board edge, and the strip between them
        // drops out as waste. A single line centred in the gap would only score
        // the middle of that scrap and separate nothing.
        // With gap = 0 the two edges coincide, so only one line is drawn.

        // Vertical: per column boundary, spanning the full panel height.
        For i := 0 To Cols Do
        Begin
            DoLine := True;
            If (i = 0)    And (Not SideRails) Then DoLine := False;  // milled edge
            If (i = Cols) And (Not SideRails) Then DoLine := False;

            If DoLine Then
            Begin
                If i = 0 Then
                Begin
                    AddLine(Panel, VLayer, OX, BY, OX, BY + PanelH, VW);
                    Inc(nLines);
                End
                Else If i = Cols Then
                Begin
                    xline := OX + BoardsW;
                    AddLine(Panel, VLayer, xline, BY, xline, BY + PanelH, VW);
                    Inc(nLines);
                End
                Else
                Begin
                    // trailing edge of column i-1
                    xline := OX + i * PitchX - GapX;
                    AddLine(Panel, VLayer, xline, BY, xline, BY + PanelH, VW);
                    Inc(nLines);

                    // leading edge of column i - same coordinate when GapX = 0
                    If GapX > 0 Then
                    Begin
                        xline := OX + i * PitchX;
                        AddLine(Panel, VLayer, xline, BY, xline, BY + PanelH, VW);
                        Inc(nLines);
                    End;
                End;
            End;
        End;

        // Horizontal: top and bottom rails always exist, so every boundary scores.
        For i := 0 To Rows Do
        Begin
            If i = 0 Then
            Begin
                AddLine(Panel, VLayer, BX, OY, BX + PanelW, OY, VW);
                Inc(nLines);
            End
            Else If i = Rows Then
            Begin
                yline := OY + BoardsH;
                AddLine(Panel, VLayer, BX, yline, BX + PanelW, yline, VW);
                Inc(nLines);
            End
            Else
            Begin
                // trailing edge of row i-1
                yline := OY + i * PitchY - GapY;
                AddLine(Panel, VLayer, BX, yline, BX + PanelW, yline, VW);
                Inc(nLines);

                // leading edge of row i - same coordinate when GapY = 0
                If GapY > 0 Then
                Begin
                    yline := OY + i * PitchY;
                    AddLine(Panel, VLayer, BX, yline, BX + PanelW, yline, VW);
                    Inc(nLines);
                End;
            End;
        End;

        End      // ---- end of V-cut branch ----
        Else
        Begin
        // ================= mouse bites =================
        // The router traces EACH BOARD'S ACTUAL OUTLINE, translated to that
        // instance. Routing the bounding box instead leaves panel material
        // attached wherever the outline steps inward, so any board with a
        // notch or cutout comes off the panel carrying extra FR4.
        //
        // Whatever material remains between two boards' paths stays put as
        // panel webbing.
        If GOutN < 3 Then
        Begin
            Warn := Warn + #13#10 + '  - no source outline stored, bites skipped';
        End
        Else
        Begin
        // cutter centreline = outline pushed out by half the bit
        BuildRoutOutline(BitW Div 2);

        For c := 0 To Cols - 1 Do
            For r := 0 To Rows - 1 Do
            Begin
                bx0 := OX + c * PitchX;   // this instance's bbox corner
                by0 := OY + r * PitchY;

                For i := 0 To GOutN - 1 Do
                Begin
                    k2 := i + 1;
                    If k2 >= GOutN Then k2 := 0;   // close the polygon

                    AddRoutSegment(Panel, VLayer,
                                   bx0 + GRoutX[i],  by0 + GRoutY[i],
                                   bx0 + GRoutX[k2], by0 + GRoutY[k2],
                                   bx0 + GOutX[i],   by0 + GOutY[i],
                                   bx0 + GOutX[k2],  by0 + GOutY[k2],
                                   Tabs, HoleCount, TabW, BitW, HoleDia,
                                   HolePitch, HoleOff, BothSides,
                                   nHoles, nLines);
                End;
            End;
        End;

        End;     // ---- end of mouse-bite branch ----

        // ---------- 8. tooling holes ----------
        // Sections 8-10 are guarded individually. The panel itself (outline,
        // array, score lines) is already complete by this point, so a failure
        // in a decorative extra must not throw the whole build away.
        If CbTooling.Checked Then
        Try
            // Same inset from both edges, so a corner hole sits on the 45 line
            // out of its corner - as far down from the top as it is in from the
            // side. All four corners are then the same distance from the panel
            // outline, whichever way the panel is turned.
            Inset := ToolInset;

            AddToolingHole(Panel, BX + Inset,          BY + Inset,          ToolDia);
            AddToolingHole(Panel, BX + PanelW - Inset, BY + Inset,          ToolDia);
            AddToolingHole(Panel, BX + Inset,          BY + PanelH - Inset, ToolDia);
            AddToolingHole(Panel, BX + PanelW - Inset, BY + PanelH - Inset, ToolDia);
        Except
            Warn := Warn + #13#10 + '  - tooling holes failed';
        End;

        // ---------- 9. fiducials (3, asymmetric) ----------
        If CbFiducials.Checked And (Rail >= MM(cMinRailFor)) Then
        Try
            FidCu   := MM(1.0);
            FidMask := MM(2.0);
            AddFiducial(Panel, BX + Round(PanelW * 0.35), BY + Rail Div 2,
                        FidCu, FidMask);
            AddFiducial(Panel, BX + Round(PanelW * 0.65), BY + Rail Div 2,
                        FidCu, FidMask);
            AddFiducial(Panel, BX + Round(PanelW * 0.35), BY + PanelH - Rail Div 2,
                        FidCu, FidMask);
        Except
            Warn := Warn + #13#10 + '  - fiducials failed';
        End;

        // ---------- 10. title text ----------
        If CbTitle.Checked Then
        Try
            Msg := Trim(EdTitle.Text) + '  ' + IntToStr(Cols) + 'x' + IntToStr(Rows) +
                   '  ' + MMStr(PanelW) + 'x' + MMStr(PanelH) + 'mm  ' +
                   FormatDateTime('yyyy-mm-dd', Date);

            // Start clear of the corner tooling hole. Both sit centred in the
            // same rail, so without this the hole swallows the first few
            // characters - which is exactly what happened at the 2 mm default.
            TextX := MM(2.0);
            If CbTooling.Checked And (ToolInset + ToolDia Div 2 + MM(2.0) > TextX) Then
                TextX := ToolInset + ToolDia Div 2 + MM(2.0);

            AddText(Panel, eTopOverlay,
                    BX + TextX, BY + Rail Div 2 - MM(0.75),
                    Msg, MM(1.5), MM(0.2));

            // Fab note must match the method actually used - a V-cut
            // instruction on a routed panel is worse than no note at all.
            If MouseBites Then
                Msg := 'ROUT THESE PATHS - ' + MMStr(BitW) +
                       ' mm BIT - TABS BREAK AT PERFORATIONS'
            Else
                Msg := 'V-CUT ON THESE LINES - 30 DEG - 1/3 REMAINING WEB';

            AddText(Panel, VLayer,
                    BX + TextX, BY + PanelH - Rail Div 2 - MM(0.75),
                    Msg, MM(1.5), MM(0.2));
        Except
            Warn := Warn + #13#10 + '  - title text failed';
        End;

        // ---------- 11. dimension annotations ----------
        // Kept OFF the V-cut layer on purpose: that layer is what the fab reads
        // to place the scoring blade, and stray drawing lines on it would be
        // read as extra scores. Dimensions go on their own mechanical layer.
        If CbDims.Checked Then
        Try
            If LayerNo >= 32 Then DimLayerNo := LayerNo - 1
            Else                  DimLayerNo := LayerNo + 1;

            DimLayer := LayerUtils.MechanicalLayer(DimLayerNo);
            Try
                MLayer := Panel.LayerStack_V7.LayerObject_V7(DimLayer);
                If MLayer <> Nil Then
                Begin
                    MLayer.MechanicalLayerEnabled := True;
                    MLayer.Name := 'Panel Drawing';
                    Try
                        MLayer.Kind := mlDimensions;
                    Except
                    End;
                End;
            Except
            End;

            Mrg := MM(7.0);

            AddDimH(Panel, DimLayer, BX, BX + PanelW, BY - Mrg, VW,
                    MMStr(PanelW) + ' mm');

            AddDimV(Panel, DimLayer, BY, BY + PanelH, BX - Mrg, VW,
                    MMStr(PanelH) + ' mm');

            // single board pitch, so the fab can sanity-check the array step
            If Cols > 1 Then
                AddDimH(Panel, DimLayer, OX, OX + PitchX, BY - Mrg - MM(7.0), VW,
                        'pitch ' + MMStr(PitchX) + ' mm');
        Except
            Warn := Warn + #13#10 + '  - dimension annotations failed';
        End;

        // ---------- 12. fit the sheet around the panel ----------
        // Sheet properties live on TPCBSheet, not IPCB_Board, and are not
        // exposed to scripting - so use Design > Board Shape > Auto-Position.
        Try
            ResetParameters;
            RunProcess('PCB:AutoMoveSheet');
        Except
            Warn := Warn + #13#10 + '  - sheet auto-fit failed';
        End;

    Finally
        PCBServer.PostProcess;
    End;

    // View refresh only - never worth losing a finished panel over.
    Try
        Panel.ViewManager_UpdateLayerTabs;
        Panel.GraphicalView_ZoomRedraw;
    Except
    End;

    If MouseBites Then
    Begin
        Msg := 'Bites   : ' + IntToStr(nLines) + ' rout segments, ' +
               IntToStr(nHoles) + ' holes, ' + IntToStr(Tabs) +
               ' tabs/edge of ' + MMStr(TabW) + ' mm, ' +
               MMStr(BitW) + ' mm bit';
        If BothSides Then Msg := Msg + ', perforated both sides';
        If HoleOff > 0 Then
            Msg := Msg + ', holes ' + MMStr(HoleOff) + ' mm off the edge';
    End
    Else
        Msg := 'V-cuts  : ' + IntToStr(nLines) + ' score lines';

    If Warn <> '' Then
        Warn := #13#10 + #13#10 + 'Completed with problems:' + Warn + #13#10 +
                'The panel itself (outline, array, score lines) is unaffected.';

    ShowMessage('Panel built.' + #13#10 + #13#10 +
                'Array   : ' + IntToStr(Cols) + ' x ' + IntToStr(Rows) +
                ' of ' + MMStr(GBoardW) + ' x ' + MMStr(GBoardH) + ' mm' + #13#10 +
                'Panel   : ' + MMStr(PanelW) + ' x ' + MMStr(PanelH) + ' mm' + #13#10 +
                'Rails   : ' + MMStr(Rail) + ' mm' + #13#10 +
                Msg + ' on Mechanical ' + IntToStr(LayerNo) + #13#10 + #13#10 +
                'Save the panel in the same folder as the source board so the ' +
                'embedded array keeps a relative link.' + Warn);
End;


{..............................................................................}
{  Entry point - this is the name that appears in the Run Script list.         }
{  Every control is built inline; no helper takes or returns a VCL type.       }
{..............................................................................}
{..............................................................................}
{  Ask for the separation method first, so the settings dialog can be built    }
{  around the answer and simply leave out what the other method uses.          }
{                                                                              }
{  This is why the method is not a combo on the settings dialog itself.        }
{  Reacting to a combo means an OnChange handler, and that was tried: a        }
{  Procedure MethodChanged(Sender : TObject) greying out the fields V-cut does }
{  not use. Calling it raised "invalid procedure usage" at run time, so a      }
{  handler procedure is not something this interpreter will work with.         }
{                                                                              }
{  Buttons carrying a ModalResult need no handler, so the choice is made       }
{  before anything is built and the dialog is assembled around the answer.     }
{                                                                              }
{  Returns 0 for V-cut, 1 for mouse bites, -1 if cancelled.                    }
{..............................................................................}
Function AskMethod : Integer;
Var
    F : TForm;
    L : TLabel;
    B : TButton;
    R : Integer;
Begin
    Result := -1;

    F := TForm.Create(Nil);
    Try
        F.BorderStyle  := bsDialog;
        F.Caption      := 'Altium EZ Panelizer';
        F.Position     := poScreenCenter;
        F.ClientWidth  := 460;
        F.ClientHeight := 188;

        L := TLabel.Create(F);
        L.Parent := F;  L.Left := 16;  L.Top := 16;
        L.Caption := 'How should the boards come apart?';

        L := TLabel.Create(F);
        L.Parent := F;  L.Left := 16;  L.Top := 48;
        L.Caption := 'V-cut - scored along butted board edges. Needs a rectangular';

        L := TLabel.Create(F);
        L.Parent := F;  L.Left := 16;  L.Top := 66;
        L.Caption := 'board: a straight blade cannot follow a notch.';

        L := TLabel.Create(F);
        L.Parent := F;  L.Left := 16;  L.Top := 92;
        L.Caption := 'Mouse bites - routed around the real outline, held by tabs.';

        L := TLabel.Create(F);
        L.Parent := F;  L.Left := 16;  L.Top := 110;
        L.Caption := 'Follows any shape, but needs a gap of at least one bit width.';

        B := TButton.Create(F);
        B.Parent      := F;
        B.Left        := 16;   B.Top    := 140;
        B.Width       := 110;  B.Height := 30;
        B.Caption     := 'V-cut';
        B.ModalResult := mrYes;

        B := TButton.Create(F);
        B.Parent      := F;
        B.Left        := 136;  B.Top    := 140;
        B.Width       := 130;  B.Height := 30;
        B.Caption     := 'Mouse bites';
        B.ModalResult := mrNo;

        B := TButton.Create(F);
        B.Parent      := F;
        B.Left        := 344;  B.Top    := 140;
        B.Width       := 100;  B.Height := 30;
        B.Caption     := 'Cancel';
        B.ModalResult := mrCancel;

        R := F.ShowModal;
        If R = mrYes Then Result := 0
        Else If R = mrNo Then Result := 1;
    Finally
        F.Free;
    End;
End;


Procedure RunEzPanelizer;
Var
    Dlg : TOpenDialog;
    Frm : TForm;
    G   : TGroupBox;
    L   : TLabel;
    B   : TButton;
    i   : Integer;
    M   : Integer;
    Y   : Integer;
Begin
    // ---- pick the source board first, so the dialog has nothing to browse for ----
    Dlg := TOpenDialog.Create(Nil);
    Try
        Dlg.Filter := 'PCB documents (*.PcbDoc)|*.PcbDoc|All files (*.*)|*.*';
        Dlg.Title  := 'Select the source PCB document to panelize';
        If Not Dlg.Execute Then Exit;
        GSrcPath := Dlg.FileName;
    Finally
        Dlg.Free;
    End;

    If Not ReadBoardSize(GSrcPath, GBoardW, GBoardH) Then Exit;

    // ---- method, then the settings that method actually uses ----
    M := AskMethod;
    If M < 0 Then Exit;
    GMouseBites := (M = 1);

    Frm := TForm.Create(Nil);
    Try
        Frm.BorderStyle  := bsDialog;
        Frm.Position     := poScreenCenter;

        If GMouseBites Then
            Frm.Caption := 'Altium EZ Panelizer - mouse bites'
        Else
            Frm.Caption := 'Altium EZ Panelizer - V-cut';

        // Generous spacing on purpose: label widths vary with system font and
        // DPI, so every edit starts well clear of the widest label in its
        // column. Tighter positions collided at anything above 96 dpi.
        //
        // One grid throughout, so the columns line up from group to group:
        //   label col 1 x=12    edit col 1 x=150
        //   label col 2 x=250   edit col 2 x=390 (width 60, ends at 450)
        // Nothing reaches past 460, which leaves every field a margin wide
        // enough to absorb the label growth at 125-150% scaling.
        //
        // Y walks down the form as groups are added, because the mouse-bite
        // group is only there for mouse bites - hardcoded tops would leave a
        // hole in the V-cut dialog.
        Frm.ClientWidth := 540;

        L := TLabel.Create(Frm);
        L.Parent  := Frm;
        L.Left    := 12;
        L.Top     := 10;
        L.Caption := 'Source: ' + ExtractFileName(GSrcPath) + '   (' +
                     MMStr(GBoardW) + ' x ' + MMStr(GBoardH) + ' mm)';

        Y := 32;

        // ================= array =================
        G := TGroupBox.Create(Frm);
        G.Parent  := Frm;
        G.Left    := 12;
        G.Top     := Y;
        G.Width   := 516;
        G.Height  := 104;
        G.Caption := ' Array ';
        Y := Y + 112;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 26;  L.Caption := 'Columns (X):';

        EdCols := TEdit.Create(G);
        EdCols.Parent := G;  EdCols.Left := 150;  EdCols.Top := 22;
        EdCols.Width  := 60; EdCols.Text := '2';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 250;  L.Top := 26;  L.Caption := 'Rows (Y):';

        EdRows := TEdit.Create(G);
        EdRows.Parent := G;  EdRows.Left := 390;  EdRows.Top := 22;
        EdRows.Width  := 60; EdRows.Text := '3';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 53;  L.Caption := 'Gap X (mm):';

        EdGapX := TEdit.Create(G);
        EdGapX.Parent := G;  EdGapX.Left := 150;  EdGapX.Top := 49;
        EdGapX.Width  := 60; EdGapX.Text := '0';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 250;  L.Top := 53;  L.Caption := 'Gap Y (mm):';

        EdGapY := TEdit.Create(G);
        EdGapY.Parent := G;  EdGapY.Left := 390;  EdGapY.Top := 49;
        EdGapY.Width  := 60; EdGapY.Text := '0';

        // own row: this note was running past the group edge and getting cut
        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 80;
        If GMouseBites Then
            L.Caption := 'Mouse bites need a gap of at least one bit width, on both axes.'
        Else
            L.Caption := '0 = butted, which is what V-cut wants. A gap is scored twice.';

        // ================= mouse bites only =================
        // Not created at all for V-cut, which has no settings of its own - the
        // score follows the board edges and uses the gap and line width below.
        If GMouseBites Then
        Begin
            G := TGroupBox.Create(Frm);
            G.Parent  := Frm;
            G.Left    := 12;
            G.Top     := Y;
            G.Width   := 516;
            G.Height  := 184;
            G.Caption := ' Mouse bites ';
            Y := Y + 192;

            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 12;  L.Top := 26;
            L.Caption := 'Tab width (mm):';

            EdTabW := TEdit.Create(G);
            EdTabW.Parent := G;  EdTabW.Left := 150;  EdTabW.Top := 22;
            EdTabW.Width  := 60; EdTabW.Text := '5.0';

            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 250;  L.Top := 26;
            L.Caption := 'Tabs per edge:';

            EdTabs := TEdit.Create(G);
            EdTabs.Parent := G;  EdTabs.Left := 390;  EdTabs.Top := 22;
            EdTabs.Width  := 60; EdTabs.Text := '2';

            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 12;  L.Top := 53;
            L.Caption := 'Hole dia (mm):';

            EdHoleDia := TEdit.Create(G);
            EdHoleDia.Parent := G;  EdHoleDia.Left := 150;  EdHoleDia.Top := 49;
            EdHoleDia.Width  := 60; EdHoleDia.Text := '0.5';

            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 250;  L.Top := 53;
            L.Caption := 'Holes per tab:';

            EdHoleCount := TEdit.Create(G);
            EdHoleCount.Parent := G;  EdHoleCount.Left := 390;  EdHoleCount.Top := 49;
            EdHoleCount.Width  := 60; EdHoleCount.Text := '5';

            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 12;  L.Top := 80;
            L.Caption := 'Hole pitch (mm):';

            EdHolePitch := TEdit.Create(G);
            EdHolePitch.Parent := G;  EdHolePitch.Left := 150;  EdHolePitch.Top := 76;
            EdHolePitch.Width  := 60; EdHolePitch.Text := '1.0';

            // Was crammed into a third column against the group edge, where it
            // got clipped - it is an ordinary setting and now sits on the grid.
            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 250;  L.Top := 80;
            L.Caption := 'Bit (mm):';

            EdBitDia := TEdit.Create(G);
            EdBitDia.Parent := G;  EdBitDia.Left := 390;  EdBitDia.Top := 76;
            EdBitDia.Width  := 60; EdBitDia.Text := '2.0';

            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 12;  L.Top := 107;
            L.Caption := 'Hole offset (mm):';

            EdHoleOff := TEdit.Create(G);
            EdHoleOff.Parent := G;  EdHoleOff.Left := 150;  EdHoleOff.Top := 103;
            EdHoleOff.Width  := 60; EdHoleOff.Text := '0';

            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 250;  L.Top := 107;
            L.Caption := '0 = on the board edge';

            CbBothSides := TCheckBox.Create(G);
            CbBothSides.Parent  := G;
            CbBothSides.Left    := 12;
            CbBothSides.Top     := 134;
            CbBothSides.Width   := 470;
            CbBothSides.Caption := 'Perforate both sides of each tab (board edge and far side of the cut)';
            CbBothSides.Checked := True;

            L := TLabel.Create(G);
            L.Parent := G;  L.Left := 12;  L.Top := 160;
            L.Caption := 'The drill row is centred in the tab, and must fit inside it.';
        End;

        // ================= panel / cut layer =================
        G := TGroupBox.Create(Frm);
        G.Parent  := Frm;
        G.Left    := 12;
        G.Top     := Y;
        G.Width   := 516;
        G.Height  := 106;
        G.Caption := ' Panel and cut layer ';
        Y := Y + 114;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 26;  L.Caption := 'Rail width (mm):';

        EdRail := TEdit.Create(G);
        EdRail.Parent := G;  EdRail.Left := 150;  EdRail.Top := 22;
        EdRail.Width  := 60; EdRail.Text := '5';

        CbSideRails := TCheckBox.Create(G);
        CbSideRails.Parent  := G;
        CbSideRails.Left    := 250;
        CbSideRails.Top     := 24;
        CbSideRails.Width   := 210;
        CbSideRails.Caption := 'Left / right rails as well';
        CbSideRails.Checked := True;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 55;  L.Caption := 'Cut layer:';

        CoVLayer := TComboBox.Create(G);
        CoVLayer.Parent := G;
        CoVLayer.Left   := 150;
        CoVLayer.Top    := 51;
        CoVLayer.Width  := 150;
        CoVLayer.Style  := csDropDownList;
        For i := 1 To 32 Do
            CoVLayer.Items.Add('Mechanical ' + IntToStr(i));
        CoVLayer.ItemIndex := 0;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 82;  L.Caption := 'Line width (mm):';

        EdVW := TEdit.Create(G);
        EdVW.Parent := G;  EdVW.Left := 150;  EdVW.Top := 78;
        EdVW.Width  := 60; EdVW.Text := '0.2';

        // Sat under the edits at x=110 before, lining up with nothing. On the
        // second column now, and the caption is shortened so it cannot run past
        // the group edge at a larger font - the names are in the readme.
        CbNameLayer := TCheckBox.Create(G);
        CbNameLayer.Parent  := G;
        CbNameLayer.Left    := 250;
        CbNameLayer.Top     := 80;
        CbNameLayer.Width   := 210;
        CbNameLayer.Caption := 'Rename it (V-Cut / Routing)';
        CbNameLayer.Checked := True;

        // ================= extras =================
        G := TGroupBox.Create(Frm);
        G.Parent  := Frm;
        G.Left    := 12;
        G.Top     := Y;
        G.Width   := 516;
        G.Height  := 190;
        G.Caption := ' Panel extras ';
        Y := Y + 206;

        CbTooling := TCheckBox.Create(G);
        CbTooling.Parent  := G;
        CbTooling.Left    := 12;
        CbTooling.Top     := 22;
        CbTooling.Width   := 220;
        CbTooling.Caption := 'Tooling holes (4, in the corners)';
        CbTooling.Checked := True;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 250;  L.Top := 24;  L.Caption := 'Hole dia (mm):';

        EdToolDia := TEdit.Create(G);
        EdToolDia.Parent := G;  EdToolDia.Left := 390;  EdToolDia.Top := 20;
        EdToolDia.Width  := 60; EdToolDia.Text := '3.0';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 32;  L.Top := 52;
        L.Caption := 'Distance from both edges (mm), to hole centre:';

        EdToolInset := TEdit.Create(G);
        EdToolInset.Parent := G;  EdToolInset.Left := 390;  EdToolInset.Top := 48;
        EdToolInset.Width  := 60; EdToolInset.Text := '2.5';

        CbFiducials := TCheckBox.Create(G);
        CbFiducials.Parent  := G;
        CbFiducials.Left    := 12;
        CbFiducials.Top     := 78;
        CbFiducials.Width   := 440;
        CbFiducials.Caption := 'Fiducials (3, asymmetric, 1 mm / 2 mm mask)';
        CbFiducials.Checked := True;

        CbTitle := TCheckBox.Create(G);
        CbTitle.Parent  := G;
        CbTitle.Left    := 12;
        CbTitle.Top     := 106;
        CbTitle.Width   := 440;
        CbTitle.Caption := 'Panel title text in bottom rail';
        CbTitle.Checked := True;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 32;  L.Top := 136;  L.Caption := 'Text:';

        EdTitle := TEdit.Create(G);
        EdTitle.Parent := G;  EdTitle.Left := 80;  EdTitle.Top := 132;
        EdTitle.Width  := 370; EdTitle.Text := 'PANEL';

        CbDims := TCheckBox.Create(G);
        CbDims.Parent  := G;
        CbDims.Left    := 12;
        CbDims.Top     := 162;
        CbDims.Width   := 460;
        CbDims.Caption := 'Dimension annotations (own mechanical layer)';
        CbDims.Checked := True;

        // ========== buttons: ModalResult, so they need no handler ==========
        B := TButton.Create(Frm);
        B.Parent      := Frm;
        B.Left        := 316;
        B.Top         := Y;
        B.Width       := 100;
        B.Height      := 30;
        B.Caption     := 'Build Panel';
        B.ModalResult := mrOK;

        B := TButton.Create(Frm);
        B.Parent      := Frm;
        B.Left        := 428;
        B.Top         := Y;
        B.Width       := 100;
        B.Height      := 30;
        B.Caption     := 'Cancel';
        B.ModalResult := mrCancel;

        Frm.ClientHeight := Y + 46;

        If Frm.ShowModal = mrOK Then DoBuildPanel;
    Finally
        Frm.Free;
    End;
End;


End.



