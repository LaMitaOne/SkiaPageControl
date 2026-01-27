unit SkiaPageControl;

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, Vcl.Controls, Vcl.ExtCtrls, Vcl.Graphics, VCL.Forms, Vcl.ComCtrls,
  System.Types, System.UITypes,
  Skia, VCL.Skia, Skia.API;

type
  TPageChangeEvent = procedure(Sender: TObject; NewIndex: Integer) of object;

  TPageChangeEffect = (ceNone, ceFade, ceSlideLeft, cePageblur);

  TSkiaPageControl = class(TCustomControl)
  private
    FPages: TList;
    FActiveIndex: Integer;
    FEffect: TPageChangeEffect;
    FOverlay: TSkPaintBox;
    FTabs: TTabControl; // NEW: Built-in Tabs
    FOnChange: TPageChangeEvent;
    FBitmapOld: TBitmap;
    FBitmapNew: TBitmap;
    FImageOld: ISkImage;
    FImageNew: ISkImage;
    FProgress: Single;
    FAnimating: Boolean;
    FTargetIndex: Integer;
    FTimer: TTimer;

    procedure SetActiveIndex(const Value: Integer);
    procedure SetActivePage(const Value: TPanel);
    function GetActivePage: TPanel;
    function GetTabs: TStrings;
    procedure SetTabs(const Value: TStrings);
    procedure SetEffect(const Value: TPageChangeEffect);

    procedure UpdatePageVisibility;
    procedure DoOverlayDraw(ASender: TObject; const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure RunTransition(AFromIndex, AToIndex: Integer);
    procedure OnTimer(Sender: TObject);
    procedure OnTabChange(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddPage(APanel: TPanel); // Now automatically adds a tab
    procedure GoToPage(AIndex: Integer);
  published
    property Align default alClient;
    property ActiveIndex: Integer read FActiveIndex write SetActiveIndex default -1;
    property ActivePage: TPanel read GetActivePage write SetActivePage;
    property Effect: TPageChangeEffect read FEffect write SetEffect default cePageblur;
    property Tabs: TStrings read GetTabs write SetTabs; // NEW: Editable in IDE
    property OnChange: TPageChangeEvent read FOnChange write FOnChange;
    property Color default clBlack;
    property ParentColor default False;
    property TabStop default True;
    property ParentBackground default False;
  end;

implementation

{ Helper: Render Panel to Memory }

function RenderPanelToBitmap(APanel: TPanel): TBitmap;
var
  LDC: HDC;
begin
  Result := TBitmap.Create;
  Result.SetSize(APanel.Width, APanel.Height);
  Result.PixelFormat := pf32bit;

  LDC := GetDC(TWinControl(APanel).Handle);
  try
    BitBlt(Result.Canvas.Handle, 0, 0, Result.Width, Result.Height, LDC, 0, 0, SRCCOPY);
  finally
    ReleaseDC(TWinControl(APanel).Handle, LDC);
  end;
end;

{ Helper: Convert VCL Bitmap to Skia Image }

function BitmapToSkImage(Bmp: TBitmap): ISkImage;
var
  MS: TMemoryStream;
begin
  Result := nil;
  if not Assigned(Bmp) then Exit;

  MS := TMemoryStream.Create;
  try
    Bmp.SaveToStream(MS);
    MS.Position := 0;
    Result := TSkImage.MakeFromEncodedStream(MS);
  finally
    MS.Free;
  end;
end;

{ TSkiaPageControl }

constructor TSkiaPageControl.Create(AOwner: TComponent);
begin
  inherited;
  FPages := TList.Create;
  FActiveIndex := -1;
  FAnimating := False;
  FProgress := 0.0;
  FEffect := ceSlideLeft;   //ceNone, ceFade, ceSlideLeft, cePageblur
  FTargetIndex := -1;

  Width := 300;
  Height := 200;
  Align := alClient;
  DoubleBuffered := True;
  Color := clBlack;
  ParentColor := False;
  ParentBackground := False;

  // 1. Create Skia Overlay (Background for Transition)
  FOverlay := TSkPaintBox.Create(Self);
  FOverlay.Parent := Self;
  FOverlay.Align := alClient;
  FOverlay.Visible := False;
  FOverlay.OnDraw := DoOverlayDraw;
  FOverlay.ControlStyle := FOverlay.ControlStyle - [csOpaque];

  // 2. Create Tabs (Foreground for Switching)
  FTabs := TTabControl.Create(Self);
  FTabs.Parent := Self;
  FTabs.Align := alTop;
  FTabs.Height := 28; // Standard Tab Height
  FTabs.TabPosition := tpTop;
  FTabs.OnChange := OnTabChange;

  // 3. Create Animation Timer
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 15;
  FTimer.OnTimer := OnTimer;
end;

destructor TSkiaPageControl.Destroy;
begin
  FTimer.Free;
  FPages.Free;
  inherited;
end;

procedure TSkiaPageControl.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  Message.Result := 1;
end;

procedure TSkiaPageControl.Resize;
begin
  inherited;
  if Assigned(FOverlay) and FOverlay.Visible then
    FOverlay.Invalidate;
end;

procedure TSkiaPageControl.SetEffect(const Value: TPageChangeEffect);
begin
  if FEffect <> Value then
    FEffect := Value;
end;

function TSkiaPageControl.GetTabs: TStrings;
begin
  Result := FTabs.Tabs;
end;

procedure TSkiaPageControl.SetTabs(const Value: TStrings);
begin
  FTabs.Tabs.Assign(Value);
end;

function TSkiaPageControl.GetActivePage: TPanel;
begin
  if (FActiveIndex >= 0) and (FActiveIndex < FPages.Count) then
    Result := TPanel(FPages[FActiveIndex])
  else
    Result := nil;
end;

procedure TSkiaPageControl.SetActivePage(const Value: TPanel);
begin
  if Assigned(Value) then
    ActiveIndex := FPages.IndexOf(Value)
  else
    ActiveIndex := -1;
end;

procedure TSkiaPageControl.AddPage(APanel: TPanel);
begin
  if Assigned(APanel) then
  begin
    APanel.Parent := Self;
    APanel.Align := alClient;
    APanel.Visible := False;
    APanel.BevelOuter := bvNone;
    FPages.Add(APanel);

    // Add Tab automatically
    FTabs.Tabs.Add(APanel.Name); // Uses the Panel Name as Tab Caption

    if FPages.Count = 1 then
      ActiveIndex := 0;
  end;
end;

procedure TSkiaPageControl.OnTabChange(Sender: TObject);
begin
  // User clicked a Tab -> Trigger Animation
  if FTabs.TabIndex <> FActiveIndex then
    ActiveIndex := FTabs.TabIndex;
end;

procedure TSkiaPageControl.SetActiveIndex(const Value: Integer);
begin
  if (FActiveIndex <> Value) and (Value >= -1) and (Value < FPages.Count) then
  begin
    // Sync the Tab Control visually
    if (Value >= 0) and (FTabs.TabIndex <> Value) then
      FTabs.TabIndex := Value;

    if not FAnimating then
      RunTransition(FActiveIndex, Value);
  end;
end;

procedure TSkiaPageControl.UpdatePageVisibility;
var
  i: Integer;
begin
  for i := 0 to FPages.Count - 1 do
  begin
    TPanel(FPages[i]).Visible := (i = FActiveIndex);
    if TPanel(FPages[i]).Visible then
      TPanel(FPages[i]).BringToFront;
  end;
end;

procedure TSkiaPageControl.GoToPage(AIndex: Integer);
begin
  SetActiveIndex(AIndex);
end;

// --- Effect Drawing Routines ---

procedure DrawEffectFade(const ACanvas: ISkCanvas; const AOld, ATo: ISkImage; const AProgress: Single; const ARect: TRectF);
var
  LPaint: ISkPaint;
begin
  LPaint := TSkPaint.Create;
  LPaint.SetAlphaf(1.0 - AProgress);
  if Assigned(AOld) then ACanvas.DrawImage(AOld, 0, 0, TSkSamplingOptions.High, LPaint);
  LPaint.SetAlphaf(AProgress);
  if Assigned(ATo) then ACanvas.DrawImage(ATo, 0, 0, TSkSamplingOptions.High, LPaint);
end;

procedure DrawEffectSlideRight(const ACanvas: ISkCanvas; const AOld, ATo: ISkImage; const AProgress: Single; const ARect: TRectF);
var
  LOffset: Single;
begin
  LOffset := ARect.Width * AProgress;
  ACanvas.Save;
  try
    ACanvas.ClipRect(ARect);
    ACanvas.Translate(-LOffset, 0);
    if Assigned(AOld) then ACanvas.DrawImage(AOld, 0, 0);
    ACanvas.Translate(ARect.Width * 2, 0);
    if Assigned(ATo) then ACanvas.DrawImage(ATo, 0, 0);
  finally
    ACanvas.Restore;
  end;
end;

procedure DrawEffectPageBlur(const ACanvas: ISkCanvas; const AOld, ATo: ISkImage; const AProgress: Single; const ARect: TRectF);
var
  LPaint: ISkPaint;
  LBlurSigma: Single;
  LAlpha: Single;
begin
  if not Assigned(AOld) then Exit;
  LBlurSigma := 30.0 * AProgress;
  LAlpha := 1.0 - AProgress;
  if LAlpha <= 0 then Exit;

  LPaint := TSkPaint.Create;
  LPaint.ImageFilter := TSkImageFilter.MakeBlur(LBlurSigma, LBlurSigma, nil, TSkTileMode.Clamp);
  LPaint.SetAlphaf(LAlpha);
  ACanvas.DrawImage(AOld, 0, 0, TSkSamplingOptions.High, LPaint);
end;

// --- Main Logic ---

procedure TSkiaPageControl.RunTransition(AFromIndex, AToIndex: Integer);
var
  LFromPanel, LToPanel: TPanel;
begin
  if FAnimating or (AFromIndex = AToIndex) then Exit;

  if AFromIndex = -1 then
  begin
    FActiveIndex := AToIndex;
    UpdatePageVisibility;
    Exit;
  end;

  if FEffect = ceNone then
  begin
    FActiveIndex := AToIndex;
    UpdatePageVisibility;
    Exit;
  end;

  LFromPanel := TPanel(FPages[AFromIndex]);
  LToPanel := TPanel(FPages[AToIndex]);

  FBitmapOld := TBitmap.Create;
  FBitmapNew := TBitmap.Create;
  FImageOld := nil;
  FImageNew := nil;

  try
    FBitmapOld.SetSize(Self.ClientWidth, Self.ClientHeight);
    FBitmapNew.SetSize(Self.ClientWidth, Self.ClientHeight);

    // CAPTURE OLD PAGE
    FBitmapOld.Assign(RenderPanelToBitmap(LFromPanel));
    FImageOld := BitmapToSkImage(FBitmapOld);
    FBitmapNew.Assign(RenderPanelToBitmap(LToPanel));
    FImageNew := BitmapToSkImage(FBitmapNew);

    // SWITCH TO NEW PAGE
    FActiveIndex := AToIndex;
    UpdatePageVisibility;

    // MOVE SKIA OVERLAY TO NEW PAGE
    FOverlay.Parent := LToPanel;
    FOverlay.Align := alClient;

    // Draw buffer before showing, else we get some flicker
    FOverlay.Redraw;
    FOverlay.Visible := True;
    FOverlay.BringToFront;

    // START ANIMATION
    FAnimating := True;
    FProgress := 0.0;
    FTargetIndex := AToIndex;
    FTimer.Enabled := True;

  finally
  end;
end;

procedure TSkiaPageControl.OnTimer(Sender: TObject);
begin
  FProgress := FProgress + 0.02;

  if FProgress >= 1.0 then
  begin
    FTimer.Enabled := False;
    FOverlay.Visible := False;

    FreeAndNil(FBitmapOld);
    FreeAndNil(FBitmapNew);
    FImageOld := nil;
    FImageNew := nil;
    FAnimating := False;

    FActiveIndex := FTargetIndex;
    UpdatePageVisibility;

    if Assigned(FOnChange) then FOnChange(Self, FActiveIndex);
  end
  else
  begin
    FOverlay.Redraw;
  end;
end;

procedure TSkiaPageControl.DoOverlayDraw(ASender: TObject; const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  LRect: TRectF;
begin
  ACanvas.Clear(TAlphaColors.Null);
  LRect := TRectF.Create(0, 0, Self.ClientWidth, Self.ClientHeight);

  case FEffect of
    ceFade:      DrawEffectFade(ACanvas, FImageOld, FImageNew, FProgress, LRect);
    ceSlideLeft:DrawEffectSlideRight(ACanvas, FImageOld, FImageNew, FProgress, LRect);
    cePageblur:  DrawEffectPageBlur(ACanvas, FImageOld, FImageNew, FProgress, LRect);
  end;
end;

end.
