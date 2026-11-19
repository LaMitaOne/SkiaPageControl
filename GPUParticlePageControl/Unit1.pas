{*******************************************************************************
  Unit1 - FMX demo form for TGPUParticlePageControl
********************************************************************************
  This is the upgraded demo of what was previously the VCL SkiaPageControl
  sample. The new particle transition control is FMX-only (it derives from
  TSkiaCustomThreadedBase, which is an FMX Skia4Delphi control), so this
  form is now an FMX form.


  Flow:
    - 3 page panels live in a TLayout below a TTabControl.
    - One tab per page. Clicking a tab fires OnTabChange.
    - OnTabChange captures BOTH panels (MakeScreenshot) as BGRA byte buffers,
      pushes them into TGPUParticlePageControl via SetImageOld/SetImageNew,
      brings the particle control to the front (Visible := True), and calls
      StartTransition.
    - The particle control renders the transition in its background GL thread.
    - OnTransitionComplete fires on the UI thread, hides the overlay, the
      new page is already showing underneath.

  Capture note: FMX MakeScreenshot returns a TBitmap whose memory layout is
  BGRA on Windows (which is what the particle control's SetImageOld/New
  expects - it uploads via GL_BGRA / GL_UNSIGNED_BYTE). On other platforms
  FMX bitmaps are RGBA and would need a swizzle; this demo targets Windows
  (the GL 4.3 context path is Windows-only anyway).
*******************************************************************************}

unit Unit1;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Forms, FMX.Controls, FMX.StdCtrls, FMX.Layouts, FMX.Types,
  FMX.Graphics, FMX.Objects, FMX.Dialogs, FMX.TabControl,
  uGPUParticlePageControl;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    FPageHost: TLayout;
    FPages: array of TLayout;
    FTabControl: TTabControl;
    FParticleCtrl: TGPUParticlePageControl;
    FActiveIndex: Integer;
    FSwitching: Boolean;

    procedure CreateUI;
    procedure OnTabChange(Sender: TObject);
    procedure OnTransitionComplete(Sender: TObject);
    procedure CapturePageToBGRA(APage: TLayout; out ABGRA: TBytes; out AW, AH: Integer);
    procedure DoSwitchPage(ANewIndex: Integer);
  public
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

procedure TForm1.FormCreate(Sender: TObject);
begin
  CreateUI;
end;

procedure TForm1.CreateUI;
const
  { Three pages with distinct background colors + a few decorations so the
    particle transition has something interesting to morph between. }
  CNames:  array[0..2] of string       = ('Settings', 'Data', 'About');
  CColors: array[0..2] of TAlphaColor   = ($FF202040, $FF402020, $FF204020);
  CAccent: array[0..2] of TAlphaColor  = ($FF66AAFF, $FFFFAA66, $FF88FF88);
var
  I: Integer;
  LTab: TTabItem;
  LTitle: TLabel;
  LBg: TRectangle;
  LRect: TRectangle;
  LCircle: TCircle;
begin
  ClientWidth := 720;
  ClientHeight := 480;
  Position := TFormPosition.ScreenCenter;
  Caption := 'GPUComponents.PageControl - Particle Transition';

  // Form background: black. The page host layout is transparent, so any
  // pixel not covered by a page rectangle would otherwise show the form's
  // default (white) fill - that is the "white border" you saw above the
  // tab bar and around pages. Setting it to black also matches the
  // particle control's clear color, so the still-frame and the animation
  // have the same backdrop.
  Fill.Kind := TBrushKind.Solid;
  Fill.Color := TAlphaColors.Black;

  // --- Tab bar at the top -------------------------------------------------
  // Note: FMX TTabControl has no TabWidth property (only TabHeight).
  // Tab widths are computed from content/style automatically. We set
  // BOTH Height (the control's own height = the bar band height) and
  // TabHeight (the tab buttons inside). With Align=alTop, only Height
  // actually sizes the control - without it the bar was full default
  // height and the rest of the form showed through as the white gap.
  FTabControl := TTabControl.Create(Self);
  FTabControl.Parent := Self;
  FTabControl.Align := TAlignLayout.Top;
  FTabControl.Height := 34;
  FTabControl.TabHeight := 30;
  FTabControl.TabPosition := TTabPosition.Top;
  FTabControl.OnChange := OnTabChange;

  // --- Page host layout (fills below tab bar) -----------------------------
  FPageHost := TLayout.Create(Self);
  FPageHost.Parent := Self;
  FPageHost.Align := TAlignLayout.Client;

  SetLength(FPages, 3);

  for I := 0 to 2 do
  begin
    // Tab entry
    LTab := TTabItem.Create(FTabControl);
    LTab.Text := CNames[I];
    LTab.Parent := FTabControl;
    LTab.Index := I;

    // Page container: a plain TLayout. FMX TPanel is a styled control and
    // does not expose a Color property - the background comes from the
    // style. Instead we layer a TRectangle (alClient) under the page
    // content, which gives us direct control of the background color.
    // TLayout itself is transparent, so the rectangle shows through.
    FPages[I] := TLayout.Create(Self);
    FPages[I].Parent := FPageHost;
    FPages[I].Align := TAlignLayout.Client;
    FPages[I].Visible := (I = 0);

    LBg := TRectangle.Create(FPages[I]);
    LBg.Parent := FPages[I];
    LBg.Align := TAlignLayout.Client;
    // IMPORTANT: set Fill.Kind BEFORE Fill.Color. In FMX, assigning Kind
    // can reset the internal color cache to claNull; if you set Color
    // first and Kind second, the Color is silently dropped and the
    // rectangle renders transparent. This was the cause of the page
    // background being white at rest (the dark color never took effect).
    LBg.Fill.Kind := TBrushKind.Solid;
    LBg.Fill.Color := CColors[I];
    LBg.Stroke.Kind := TBrushKind.None;
    LBg.SendToBack;

    // Page title
    LTitle := TLabel.Create(FPages[I]);
    LTitle.Parent := FPages[I];
    LTitle.Text := CNames[I] + ' Page';
    LTitle.StyledSettings := [];
    LTitle.TextSettings.Font.Size := 26;
    LTitle.TextSettings.Font.Family := 'Segoe UI';
    LTitle.TextSettings.FontColor := TAlphaColors.White;
    LTitle.TextSettings.HorzAlign := TTextAlign.Leading;
    LTitle.TextSettings.VertAlign := TTextAlign.Center;
    LTitle.Align := TAlignLayout.Top;
    LTitle.Margins.Top := 28;
    LTitle.Margins.Left := 28;
    LTitle.Height := 44;

    // Decorative rectangle (different position per page so the morph shows)
    LRect := TRectangle.Create(FPages[I]);
    LRect.Parent := FPages[I];
    // Kind before Color (see LBg above for why).
    LRect.Fill.Kind := TBrushKind.Solid;
    LRect.Fill.Color := CAccent[I];
    LRect.Stroke.Kind := TBrushKind.None;
    case I of
      0: LRect.SetBounds(60, 120, 180, 90);
      1: LRect.SetBounds(380, 160, 200, 120);
      2: LRect.SetBounds(220, 110, 150, 150);
    end;
    LRect.XRadius := 12;
    LRect.YRadius := 12;
    LRect.Visible := True;

    // Decorative circle (also different position per page)
    LCircle := TCircle.Create(FPages[I]);
    LCircle.Parent := FPages[I];
    // Kind before Color (see LBg above for why).
    LCircle.Fill.Kind := TBrushKind.Solid;
    LCircle.Fill.Color := CAccent[(I + 1) mod 3];
    LCircle.Stroke.Kind := TBrushKind.None;
    case I of
      0: LCircle.SetBounds(420, 240, 110, 110);
      1: LCircle.SetBounds(80, 80, 90, 90);
      2: LCircle.SetBounds(440, 60, 140, 140);
    end;
    LCircle.Visible := True;
  end;

  // --- Particle control overlay (covers the page host, hidden until needed) -
  FParticleCtrl := TGPUParticlePageControl.Create(Self);
  FParticleCtrl.Parent := FPageHost;
  FParticleCtrl.Align := TAlignLayout.Client;
  FParticleCtrl.Visible := False;       // hidden; only shown during transitions
  FParticleCtrl.BringToFront;
  FParticleCtrl.OnTransitionComplete := OnTransitionComplete;
  FParticleCtrl.WobbleStrength := 1.0;
  FParticleCtrl.TrailDecay := 0.86;
  // Pre-activate the render thread at form creation. The power-saving
  // early-out in RenderEffect means the GL thread does NOT dispatch compute
  // shaders while idle - so the steady-state GPU cost is 0% - but the
  // OpenGL context is already initialized and the GL function pointers
  // (glUseProgram, glDispatchCompute, ...) are loaded. This eliminates the
  // one-time stutter on the FIRST tab click that would otherwise be spent
  // in InitOffscreenGL (context creation, shader compilation, PBO
  // allocation). Visible is still False, so the user sees nothing - the
  // overlay is purely dormant until the first DoSwitchPage.
  FParticleCtrl.Active := True;

  FActiveIndex := 0;
  FSwitching := False;
end;

procedure TForm1.CapturePageToBGRA(APage: TLayout; out ABGRA: TBytes; out AW, AH: Integer);
var
  Bmp: TBitmap;
  W, H, Y, RowBytes: Integer;
  Data: TBitmapData;
  WasVisible: Boolean;
begin
  ABGRA := nil;
  AW := 0;
  AH := 0;
  if not Assigned(APage) then
    Exit;
  W := Round(APage.Width);
  H := Round(APage.Height);
  if (W <= 0) or (H <= 0) then
    Exit;

  // MakeScreenshot uses PaintTo, which works for invisible controls in
  // principle, but in practice a panel that has never been laid out on
  // screen can come back empty (controls inside it have no cached
  // positions). To be safe we make the page visible for the duration of
  // the capture and push it to the back so it does not flash on top of
  // the currently visible page. The overlay covers the host during the
  // transition anyway, so a one-frame visibility flip is invisible to
  // the user.
  WasVisible := APage.Visible;
  APage.Visible := True;
  APage.SendToBack;
  try
    // Force a layout pass WITHOUT calling Application.ProcessMessages.
    // ProcessMessages is risky here: it can re-enter OnTabChange when the user
    // clicks fast, and can briefly flash the panel on screen.
    // Note: TLayout descends directly from TControl, not TStyledControl, so
    // it has no NeedStyleLookup / ApplyStyleLookup methods - those only exist
    // on styled controls (TPanel, TLabel, ...). RecalcAbsolute is public on
    // TControl and walks the parent chain to recompute absolute positions,
    // which is enough for MakeScreenshot to render the children correctly
    // even when the page was invisible up to this point (the children were
    // positioned via SetBounds at creation time, so their local rects are
    // already valid).
    APage.RecalcAbsolute;
    Bmp := APage.MakeScreenshot;
  finally
    if not WasVisible then
      APage.Visible := False;
  end;

  if Bmp = nil then
    Exit;

  // IMPORTANT: on High-DPI displays (125% / 150% scaling) MakeScreenshot
  // returns a bitmap in PHYSICAL pixels, so Bmp.Width can be larger than
  // APage.Width. We must derive AW/AH from the bitmap, not from the layout.
  // Data.Pitch can also be larger than Bmp.Width * 4 (row alignment), so a
  // single bulk Move would skew the image. We copy row by row.
  AW := Bmp.Width;
  AH := Bmp.Height;
  RowBytes := AW * 4;

  try
    if Bmp.Map(TMapAccess.Read, Data) then
    try
      SetLength(ABGRA, AW * AH * 4);
      // FMX TBitmap is BGRA on Windows. The particle control uploads with
      // GL_BGRA / GL_UNSIGNED_BYTE, so the byte order matches. On macOS/iOS
      // FMX uses RGBA - if you ever port this, swizzle here.
      for Y := 0 to AH - 1 do
        Move(PByte(Data.Data)[Y * Data.Pitch], ABGRA[Y * RowBytes], RowBytes);
    finally
      Bmp.Unmap(Data);
    end;
  finally
    Bmp.Free;
  end;
end;

procedure TForm1.DoSwitchPage(ANewIndex: Integer);
var
  OldBGRA, NewBGRA: TBytes;
  OW, OH, NW, NH: Integer;
begin
  if FSwitching or (ANewIndex = FActiveIndex)
     or (ANewIndex < 0) or (ANewIndex >= Length(FPages)) then
    Exit;
  FSwitching := True;

  // Capture BOTH pages BEFORE switching visibility. MakeScreenshot works
  // on invisible controls, so we can grab the target page without flashing
  // it on screen.
  CapturePageToBGRA(FPages[FActiveIndex], OldBGRA, OW, OH);
  CapturePageToBGRA(FPages[ANewIndex],    NewBGRA, NW, NH);

  if (OW = 0) or (OH = 0) or (NW = 0) or (NH = 0) then
  begin
    // Screenshot failed - bail out and just do a hard switch.
    FPages[FActiveIndex].Visible := False;
    FPages[ANewIndex].Visible := True;
    FPages[ANewIndex].BringToFront;
    FActiveIndex := ANewIndex;
    FSwitching := False;
    Exit;
  end;

  // Push both images to the particle control.
  FParticleCtrl.SetImageOld(OldBGRA, OW, OH);
  FParticleCtrl.SetImageNew(NewBGRA, NW, NH);

  // Swap the underlying pages now - the particle overlay covers them
  // during the transition, so the user does not see the instant swap.
  FPages[FActiveIndex].Visible := False;
  FPages[ANewIndex].Visible := True;
  FPages[ANewIndex].BringToFront;

  // Bring the particle control on top and start the transition.
  FParticleCtrl.Visible := True;
  FParticleCtrl.BringToFront;
  if not FParticleCtrl.Active then
    FParticleCtrl.Active := True;
  FParticleCtrl.StartTransition(1.2);

  FActiveIndex := ANewIndex;
end;

procedure TForm1.OnTabChange(Sender: TObject);
begin
  if FSwitching then
    Exit;
  if FTabControl.TabIndex = FActiveIndex then
    Exit;
  DoSwitchPage(FTabControl.TabIndex);
end;

procedure TForm1.OnTransitionComplete(Sender: TObject);
begin
  // Fired on the UI thread (marshalled by the particle control via
  // TThread.Queue). The new page is already showing underneath; we just
  // drop the overlay and unlock tab switching.
  FParticleCtrl.Visible := False;
  FSwitching := False;
end;

end.
