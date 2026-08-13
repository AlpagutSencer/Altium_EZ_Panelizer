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
{  The dialog is built inline and its buttons use ModalResult, so no VCL type  }
{  appears in any signature and no event handler has to be bound. DelphiScript }
{  drops a whole unit from the Run Script list, with no error shown, if either }
{  is got wrong - so both are avoided deliberately.                            }
{                                                                              }
{  METHOD NOTES                                                                }
{    V-cut: a straight blade cut, so it must run clear across the panel. With  }
{    a gap, each interior boundary is scored twice - once per board edge.      }
{                                                                              }
{    Mouse bites: the router traces each board's ACTUAL outline, so notches    }
{    and cutouts are followed. The path runs on the outline itself and the     }
{    fab applies cutter compensation. A gap of at least one bit width is       }
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
    CbDims                           : TCheckBox;
    CoVLayer, CoMethod               : TComboBox;
    EdTabW, EdTabs                   : TEdit;
    EdHoleDia, EdHoleCount, EdBitDia : TEdit;
    EdHolePitch                      : TEdit;

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
                         TabW, BitW, HoleDia, HolePitch : TCoord;
                         Var nHoles, nSegs : Integer);
Var
    k, h, nH          : Integer;
    HLen, Half        : Double;
    HalfSpan          : Double;
    dx, dy, dot       : Double;
    ux, uy            : Double;
    ovx, ovy          : Double;
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
    nH := HoleCount;
    If nH < 2 Then nH := 2;
    HalfSpan := (nH - 1) * (HolePitch * 1.0) / 2;

    For k := 0 To Tabs - 1 Do
    Begin
        c := HLen * (2 * k + 1) / (2 * Tabs);   // same measure as the gap above
        For h := 0 To nH - 1 Do
        Begin
            p := c - HalfSpan + (HolePitch * 1.0) * h;
            AddBiteHole(Board, HX1 + Round(ux * p), HY1 + Round(uy * p), HoleDia);
            Inc(nHoles);
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
    MouseBites            : Boolean;
    TabW, HoleDia, HolePitch : TCoord;
    HoleCount             : Integer;
    BitW                  : TCoord;
    ARect                 : TCoordRect;
    ax, ay                : TCoord;
    bx0, by0              : TCoord;
    c, r, k2              : Integer;
    Tabs, nHoles          : Integer;
    ToolInset, TextX      : TCoord;
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
    ToolInset := MM(ParseNum(EdToolInset.Text, 5.0));
    SideRails := CbSideRails.Checked;

    // Keep the hole fully inside the panel even if a small inset is typed.
    If ToolInset < ToolDia Then ToolInset := ToolDia;

    MouseBites := (CoMethod.ItemIndex = 1);
    TabW       := MM(ParseNum(EdTabW.Text, 5.0));
    Tabs       := ParseInt(EdTabs.Text, 2);
    HoleDia    := MM(ParseNum(EdHoleDia.Text, 0.5));
    HoleCount  := ParseInt(EdHoleCount.Text, 5);
    HolePitch  := MM(ParseNum(EdHolePitch.Text, 1.0));
    BitW       := MM(ParseNum(EdBitDia.Text, 2.0));
    If Tabs < 1 Then Tabs := 1;
    If HoleCount < 2 Then HoleCount := 2;
    If BitW <= 0 Then BitW := MM(2.0);

    If MouseBites Then
    Begin
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
                                   HolePitch, nHoles, nLines);
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
            Inset := ToolInset;   // hole CENTRE distance from the panel side
            AddToolingHole(Panel, BX + Inset,          BY + Rail Div 2,          ToolDia);
            AddToolingHole(Panel, BX + PanelW - Inset, BY + Rail Div 2,          ToolDia);
            AddToolingHole(Panel, BX + Inset,          BY + PanelH - Rail Div 2, ToolDia);
            AddToolingHole(Panel, BX + PanelW - Inset, BY + PanelH - Rail Div 2, ToolDia);
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
        Msg := 'Bites   : ' + IntToStr(nLines) + ' rout segments, ' +
               IntToStr(nHoles) + ' holes, ' + IntToStr(Tabs) +
               ' tabs/edge of ' + MMStr(TabW) + ' mm, ' +
               MMStr(BitW) + ' mm bit'
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
Procedure RunEzPanelizer;
Var
    Dlg : TOpenDialog;
    Frm : TForm;
    G   : TGroupBox;
    L   : TLabel;
    B   : TButton;
    i   : Integer;
Begin
    // ---- pick the source board first, so the dialog needs no event handlers ----
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

    // ---- settings dialog ----
    Frm := TForm.Create(Nil);
    Try
        Frm.BorderStyle  := bsDialog;
        Frm.Caption      := 'Altium EZ Panelizer';
        Frm.Position     := poScreenCenter;
        // Generous spacing on purpose: label widths vary with system font and
        // DPI, so every edit starts well clear of the widest label in its
        // column. Tighter positions collided at anything above 96 dpi.
        Frm.ClientWidth  := 540;
        Frm.ClientHeight := 648;

        L := TLabel.Create(Frm);
        L.Parent  := Frm;
        L.Left    := 12;
        L.Top     := 10;
        L.Caption := 'Source: ' + ExtractFileName(GSrcPath) + '   (' +
                     MMStr(GBoardW) + ' x ' + MMStr(GBoardH) + ' mm)';

        // ================= array =================
        G := TGroupBox.Create(Frm);
        G.Parent  := Frm;
        G.Left    := 12;
        G.Top     := 32;
        G.Width   := 516;
        G.Height  := 104;
        G.Caption := ' Array ';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 26;  L.Caption := 'Columns (X):';

        EdCols := TEdit.Create(G);
        EdCols.Parent := G;  EdCols.Left := 110;  EdCols.Top := 22;
        EdCols.Width  := 60; EdCols.Text := '2';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 200;  L.Top := 26;  L.Caption := 'Rows (Y):';

        EdRows := TEdit.Create(G);
        EdRows.Parent := G;  EdRows.Left := 280;  EdRows.Top := 22;
        EdRows.Width  := 60; EdRows.Text := '3';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 53;  L.Caption := 'Gap X (mm):';

        EdGapX := TEdit.Create(G);
        EdGapX.Parent := G;  EdGapX.Left := 110;  EdGapX.Top := 49;
        EdGapX.Width  := 60; EdGapX.Text := '0';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 200;  L.Top := 53;  L.Caption := 'Gap Y (mm):';

        EdGapY := TEdit.Create(G);
        EdGapY.Parent := G;  EdGapY.Left := 280;  EdGapY.Top := 49;
        EdGapY.Width  := 60; EdGapY.Text := '0';

        // own row: this note was running past the group edge and getting cut
        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 80;
        L.Caption := '0 = butted, required by V-cut.   Mouse bites need a gap of at least one bit width.';

        // ================= panel / v-cut =================
        G := TGroupBox.Create(Frm);
        G.Parent  := Frm;
        G.Left    := 12;
        G.Top     := 144;
        G.Width   := 516;
        G.Height  := 132;
        G.Caption := ' Separation method ';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 26;  L.Caption := 'Method:';

        CoMethod := TComboBox.Create(G);
        CoMethod.Parent := G;
        CoMethod.Left   := 110;
        CoMethod.Top    := 22;
        CoMethod.Width  := 290;
        CoMethod.Style  := csDropDownList;
        CoMethod.Items.Add('V-cut  (scored, boards butted)');
        CoMethod.Items.Add('Mouse bites  (routed channel + tabs)');
        CoMethod.ItemIndex := 0;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 55;  L.Caption := 'Tab width (mm):';

        EdTabW := TEdit.Create(G);
        EdTabW.Parent := G;  EdTabW.Left := 110;  EdTabW.Top := 51;
        EdTabW.Width  := 60; EdTabW.Text := '5.0';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 200;  L.Top := 55;  L.Caption := 'Tabs per edge:';

        EdTabs := TEdit.Create(G);
        EdTabs.Parent := G;  EdTabs.Left := 300;  EdTabs.Top := 51;
        EdTabs.Width  := 60; EdTabs.Text := '2';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 82;  L.Caption := 'Hole dia (mm):';

        EdHoleDia := TEdit.Create(G);
        EdHoleDia.Parent := G;  EdHoleDia.Left := 110;  EdHoleDia.Top := 78;
        EdHoleDia.Width  := 60; EdHoleDia.Text := '0.5';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 200;  L.Top := 82;  L.Caption := 'Holes per tab:';

        EdHoleCount := TEdit.Create(G);
        EdHoleCount.Parent := G;  EdHoleCount.Left := 300;  EdHoleCount.Top := 78;
        EdHoleCount.Width  := 60; EdHoleCount.Text := '5';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 386;  L.Top := 82;  L.Caption := 'Bit (mm):';

        EdBitDia := TEdit.Create(G);
        EdBitDia.Parent := G;  EdBitDia.Left := 444;  EdBitDia.Top := 78;
        EdBitDia.Width  := 60; EdBitDia.Text := '2.0';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 109;  L.Caption := 'Hole pitch (mm):';

        EdHolePitch := TEdit.Create(G);
        EdHolePitch.Parent := G;  EdHolePitch.Left := 110;  EdHolePitch.Top := 105;
        EdHolePitch.Width  := 60; EdHolePitch.Text := '1.0';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 200;  L.Top := 109;
        L.Caption := 'drill row is centred in the tab, and must fit inside it';

        // ================= panel / cut layer =================
        G := TGroupBox.Create(Frm);
        G.Parent  := Frm;
        G.Left    := 12;
        G.Top     := 284;
        G.Width   := 516;
        G.Height  := 106;
        G.Caption := ' Panel and cut layer ';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 26;  L.Caption := 'Rail width (mm):';

        EdRail := TEdit.Create(G);
        EdRail.Parent := G;  EdRail.Left := 110;  EdRail.Top := 22;
        EdRail.Width  := 60; EdRail.Text := '5';

        CbSideRails := TCheckBox.Create(G);
        CbSideRails.Parent  := G;
        CbSideRails.Left    := 200;
        CbSideRails.Top     := 24;
        CbSideRails.Width   := 220;
        CbSideRails.Caption := 'Left / right rails as well';
        CbSideRails.Checked := True;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 55;  L.Caption := 'Cut layer:';

        CoVLayer := TComboBox.Create(G);
        CoVLayer.Parent := G;
        CoVLayer.Left   := 110;
        CoVLayer.Top    := 51;
        CoVLayer.Width  := 150;
        CoVLayer.Style  := csDropDownList;
        For i := 1 To 32 Do
            CoVLayer.Items.Add('Mechanical ' + IntToStr(i));
        CoVLayer.ItemIndex := 0;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 290;  L.Top := 55;  L.Caption := 'Line width (mm):';

        EdVW := TEdit.Create(G);
        EdVW.Parent := G;  EdVW.Left := 400;  EdVW.Top := 51;
        EdVW.Width  := 60; EdVW.Text := '0.2';

        CbNameLayer := TCheckBox.Create(G);
        CbNameLayer.Parent  := G;
        CbNameLayer.Left    := 110;
        CbNameLayer.Top     := 78;
        CbNameLayer.Width   := 390;
        CbNameLayer.Caption := 'Rename that layer ("V-Cut" / "Routing")';
        CbNameLayer.Checked := True;

        // ================= extras =================
        G := TGroupBox.Create(Frm);
        G.Parent  := Frm;
        G.Left    := 12;
        G.Top     := 398;
        G.Width   := 516;
        G.Height  := 184;
        G.Caption := ' Panel extras ';

        CbTooling := TCheckBox.Create(G);
        CbTooling.Parent  := G;
        CbTooling.Left    := 12;
        CbTooling.Top     := 22;
        CbTooling.Width   := 210;
        CbTooling.Caption := 'Tooling holes (4, in rails)';
        CbTooling.Checked := True;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 240;  L.Top := 24;  L.Caption := 'Hole dia (mm):';

        EdToolDia := TEdit.Create(G);
        EdToolDia.Parent := G;  EdToolDia.Left := 340;  EdToolDia.Top := 20;
        EdToolDia.Width  := 60; EdToolDia.Text := '3.0';

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 32;  L.Top := 50;
        L.Caption := 'Edge inset from sides (mm), to hole centre:';

        EdToolInset := TEdit.Create(G);
        EdToolInset.Parent := G;  EdToolInset.Left := 340;  EdToolInset.Top := 46;
        EdToolInset.Width  := 60; EdToolInset.Text := '5.0';

        CbFiducials := TCheckBox.Create(G);
        CbFiducials.Parent  := G;
        CbFiducials.Left    := 12;
        CbFiducials.Top     := 74;
        CbFiducials.Width   := 400;
        CbFiducials.Caption := 'Fiducials (3, asymmetric, 1 mm / 2 mm mask)';
        CbFiducials.Checked := True;

        CbTitle := TCheckBox.Create(G);
        CbTitle.Parent  := G;
        CbTitle.Left    := 12;
        CbTitle.Top     := 100;
        CbTitle.Width   := 400;
        CbTitle.Caption := 'Panel title text in bottom rail';
        CbTitle.Checked := True;

        L := TLabel.Create(G);
        L.Parent := G;  L.Left := 12;  L.Top := 129;  L.Caption := 'Text:';

        EdTitle := TEdit.Create(G);
        EdTitle.Parent := G;  EdTitle.Left := 60;  EdTitle.Top := 125;
        EdTitle.Width  := 444; EdTitle.Text := 'PANEL';

        CbDims := TCheckBox.Create(G);
        CbDims.Parent  := G;
        CbDims.Left    := 12;
        CbDims.Top     := 156;
        CbDims.Width   := 490;
        CbDims.Caption := 'Dimension annotations (own mechanical layer, not the cut layer)';
        CbDims.Checked := True;

        // ========== buttons: ModalResult only, no handlers to bind ==========
        B := TButton.Create(Frm);
        B.Parent      := Frm;
        B.Left        := 316;
        B.Top         := 598;
        B.Width       := 100;
        B.Height      := 30;
        B.Caption     := 'Build Panel';
        B.ModalResult := mrOK;

        B := TButton.Create(Frm);
        B.Parent      := Frm;
        B.Left        := 428;
        B.Top         := 598;
        B.Width       := 100;
        B.Height      := 30;
        B.Caption     := 'Cancel';
        B.ModalResult := mrCancel;

        If Frm.ShowModal = mrOK Then DoBuildPanel;
    Finally
        Frm.Free;
    End;
End;


End.



