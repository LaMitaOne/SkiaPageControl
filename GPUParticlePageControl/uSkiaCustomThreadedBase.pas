{*******************************************************************************
  SkiaThreadedRenderer
********************************************************************************
  A high-performance, threaded FMX Skia component.
  Utilizing Skia4Delphi for off-screen rendering.

  Key Features:
  - Threaded Architecture: Separates Logic/Rendering from the UI Thread.
  - Non-Blocking UI: Main thread remains responsive even at high load.
  - Double Buffering: Renders to offscreen surfaces to prevent flickering.
  - Precise Frame Pacing: QPC-based absolute frame deadlines with a hybrid
    Sleep/SpinWait strategy. The actual render time is automatically
    subtracted, so high target FPS values (144+) are really reached.
  - RealFPS Monitoring: Measures the actual frames shown on screen per
    second, independent of the configured TargetFPS. Perfect for comparing
    against other renderers (e.g. Raylib).
*******************************************************************************}
{ Skia-Threaded-Renderer v1.0                                                 }
{ by Lara Miriam Tamy Reschke                                                  }
{                                                                              }
{------------------------------------------------------------------------------}
{
  Latest Changes:
   v 1.0:
   - Never had any problem in 9 months with that base at all so its time to get 1.0
   v 0.4:
   - Added RealFPS monitoring (measures actual UI presentation rate).
   - Frame counter based on TStopwatch (QPC), updated inside Draw().
   v 0.3:
   - QPC absolute-deadline frame pacing (render time is subtracted).
   - Hybrid Sleep/SpinWait + timeBeginPeriod(1) on Windows
   - DeltaTime now uses QPC
   - StopThread: real WaitFor instead of the old Sleep(100)
   v 0.2:
   - Implemented Doublebuffering logic.
}

unit uSkiaCustomThreadedBase;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.UITypes,
  System.SyncObjs, System.Diagnostics, // TStopwatch: cross-platform QPC wrapper
  FMX.Types, FMX.Controls, FMX.Skia,
  System.Skia
  {$IFDEF MSWINDOWS}
    , Winapi.MMSystem // timeBeginPeriod / timeEndPeriod
  {$ENDIF};

const
  { Busy-spin window: while less than this remains until the frame deadline,
    we spin instead of sleeping. Large enough to absorb Sleep(1) jitter
    (typically 1-2ms), small enough to keep CPU load low. }
  SPIN_THRESHOLD_NS = 2000000; // 2 ms

type
  { High Precision Timer based on TStopwatch (QPC on Windows, equivalent
    monotonic clocks on other platforms). }
  THighResTimer = record
    Frequency: Int64;
    procedure Init;
    function GetTicks: Int64; inline;
    procedure HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
  end;

  { TSkiaCustomThreadedBase
    High-performance, thread-rendered FMX Skia component with Double Buffering.

    Changes from standard:
    1. Rendering happens in the background thread (CPU Raster).
    2. The Main Thread only displays the pre-rendered image (Snapshot).
    3. RealFPS tracks how many snapshots actually reach the screen per second.
  }
  TSkiaCustomThreadedBase = class(TSkCustomControl)
  private
    { Threading & Sync }
    FThread: TThread;
    FLock: TCriticalSection;
    FTargetFPS: Integer;
    FThreadActive: Boolean;
    FPaused: Boolean;

    { Double Buffering }
    FBackBuffer: ISkImage; // Holds the finished picture from the thread

    { Logic Properties }
    FActive: Boolean;

    { RealFPS Tracking }
    FStopwatch: TStopwatch;   // Cross-platform QPC wrapper
    FFrameCount: Integer;     // Frames presented since last FPS sample
    FLastFpsTime: Double;     // Last sample timestamp (ms, QPC based)
    FRealFPS: Integer;        // Measured frames-per-second on the UI thread

    { Demo Mode State }
    FDemoRect: TRectF;
    FDemoVelocity: TPointF;
    FAngle: Single;

    { Setters }
    procedure SetActive(const Value: Boolean);
    procedure SetTargetFPS(const Value: Integer);

    { Internal Thread Methods }
    procedure ThreadSafeInvalidate;
    procedure StartThread;
    procedure StopThread;
  protected
    procedure Resize; override;
    // The Main Thread Draw - Just shows the image
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;

    { Virtual Methods - Override these in your components }
    { 1. LOGIC: Called inside the thread loop. Update math/physics here. }
    procedure UpdateLogic(const DeltaTime: Double); virtual;
    { 2. RENDER: Called inside the thread loop. Draw to the Offscreen Canvas here. }
    procedure RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double); virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { RealFPS: Actual number of frames composited to the screen per second.
      Use this to compare effective throughput against TargetFPS or other
      renderers (Raylib, MultiThreaded variant, etc.). }
    property RealFPS: Integer read FRealFPS;
  published
    property Align;
    property HitTest default True;
    property Opacity;
    property Visible;
    property Width;
    property Height;
    { Component Properties }
    property Active: Boolean read FActive write SetActive default False;
    property TargetFPS: Integer read FTargetFPS write SetTargetFPS default 60;
  end;

implementation

{==============================================================================
  THighResTimer Implementation
==============================================================================}

procedure THighResTimer.Init;
begin
  // TStopwatch.Frequency maps to QueryPerformanceFrequency on Windows
  Frequency := TStopwatch.Frequency;
end;

function THighResTimer.GetTicks: Int64;
begin
  // Monotonic, high resolution (~100ns on Windows)
  Result := TStopwatch.GetTimestamp;
end;

{ HybridWaitUntil
  Waits until the counter reaches ATargetTicks using a two-phase strategy:
    Phase 1: Sleep(1) while far from the deadline (cheap on CPU; needs
             timeBeginPeriod(1) on Windows to be accurate!).
    Phase 2: Busy-spin the remaining microseconds for frame-exact timing.
  Returns immediately if the deadline has already passed. }
procedure THighResTimer.HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
var
  SpinTicks, Remaining: Int64;
begin
  if Frequency = 0 then Exit;
  SpinTicks := (ASpinNanoseconds * Frequency) div 1000000000;

  Remaining := ATargetTicks - GetTicks;
  while Remaining > SpinTicks do
  begin
    Sleep(1);
    Remaining := ATargetTicks - GetTicks;
  end;
  while GetTicks < ATargetTicks do ;
end;

{==============================================================================
  TSkiaCustomThreadedBase
==============================================================================}

constructor TSkiaCustomThreadedBase.Create(AOwner: TComponent);
begin
  inherited;
  FLock := TCriticalSection.Create;
  FThreadActive := False;
  FPaused := True;
  FActive := False;
  FTargetFPS := 60;

  // RealFPS init
  FStopwatch := TStopwatch.Create;
  FStopwatch.Reset;
  FStopwatch.Start;
  FFrameCount := 0;
  FLastFpsTime := 0;
  FRealFPS := 0;

  SetBounds(0, 0, 300, 200);
  HitTest := True;
  // Demo Mode Init
  FDemoRect := TRectF.Create(50, 50, 100, 100);
  FDemoVelocity := TPointF.Create(150, 100);
  FAngle := 0.0;
end;

destructor TSkiaCustomThreadedBase.Destroy;
begin
  StopThread;
  FreeAndNil(FLock);
  inherited;
end;

procedure TSkiaCustomThreadedBase.Resize;
begin
  inherited;
  // Optional: If we resized, the thread needs to know to create a new sized surface.
  // Our thread logic handles this by checking Width/Height every frame.
end;

procedure TSkiaCustomThreadedBase.StartThread;
begin
  if FThreadActive then Exit;
  FThreadActive := True;

  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      Timer: THighResTimer;
      Freq, FrameTicks: Int64;
      NextFrame, NowTicks, LastFrameTicks: Int64;
      DeltaSec, TimeSec: Double;
      LocalSurface: ISkSurface;
      Snapshot: ISkImage;
      TargetRect: TRectF;
    begin
      {$IFDEF MSWINDOWS}
      // Critical on Windows: without this, Sleep(1) actually sleeps ~15.6ms
      // and any target FPS above ~60 is impossible to reach.
      timeBeginPeriod(1);
      {$ENDIF}
      try
        Timer.Init;
        Freq := Timer.Frequency;
        if Freq <= 0 then
          Freq := 10000000; // fallback: default QPC frequency (10 MHz)

        NowTicks := Timer.GetTicks;
        LastFrameTicks := NowTicks;
        NextFrame := NowTicks;

        while not TThread.CheckTerminated do
        begin
          // Measure the REAL time since the last frame (QPC precision,
          // no 49-day wrap, no 15.6ms granularity like GetTickCount).
          NowTicks := Timer.GetTicks;
          DeltaSec := (NowTicks - LastFrameTicks) / Freq;
          LastFrameTicks := NowTicks;

          // Sanity clamp: first frame or huge stall (debugger pause etc.)
          if (DeltaSec <= 0) or (DeltaSec > 0.25) then
            DeltaSec := 1 / 60;

          // 1. UPDATE LOGIC (with real measured delta time)
          if not FPaused then
            UpdateLogic(DeltaSec);

          // 2. RENDER TO OFFSCREEN BUFFER (The Magic Part)
          // We check if we have a size to avoid errors
          if (Self.Width > 0) and (Self.Height > 0) then
          begin
            // Create a temporary raster surface in memory.
            // This is safe to do in a background thread.
            LocalSurface := TSkSurface.MakeRaster(Round(Self.Width), Round(Self.Height));

            if Assigned(LocalSurface) then
            begin
              TargetRect := RectF(0, 0, Self.Width, Self.Height);

              // Monotonic seconds since counter start - safe as a
              // global animation/shader time value.
              TimeSec := NowTicks / Freq;

              // Call the user's drawing code.
              // IMPORTANT: This runs in the BACKGROUND THREAD!
              RenderEffect(LocalSurface.Canvas, TargetRect, TimeSec);

              // Convert the drawing to a snapshot image
              Snapshot := LocalSurface.MakeImageSnapshot;

              // 3. SWAP BUFFERS SAFELY
              // Lock for a very short time just to swap the pointer
              FLock.Acquire;
              try
                FBackBuffer := Snapshot; // The main thread will see this
              finally
                FLock.Release;
              end;
            end;
          end;

          // 4. REQUEST MAIN THREAD UPDATE
          // Tell the UI to refresh (it will just draw the image we just made)
          ThreadSafeInvalidate;

          // 5. FPS PACING - absolute deadline approach.
          if FTargetFPS > 0 then
            FrameTicks := Round(Freq / FTargetFPS)
          else
            FrameTicks := Freq div 60; // TargetFPS = 0: fall back to 60

          NextFrame := NextFrame + FrameTicks;

          // Drift / Desync Correction:
          // If NextFrame is in the past (e.g. UI was blocked by Trackbar drag
          // or debugger pause), we immediately reset it to NOW.
          // This ensures we never rush a burst of frames and always wait
          // exactly 1 frame interval before the next render.
          NowTicks := Timer.GetTicks;
          if NextFrame <= NowTicks then
            NextFrame := NowTicks + FrameTicks;

          // Hybrid wait: Sleep for the bulk, spin the last ~2ms exactly.
          Timer.HybridWaitUntil(NextFrame, SPIN_THRESHOLD_NS);
        end;
      finally
        FThreadActive := False;
        {$IFDEF MSWINDOWS}
        timeEndPeriod(1);
        {$ENDIF}
      end;
    end);

  FThread.FreeOnTerminate := False; // we own the shutdown (see StopThread)
  FThread.Start;
end;

procedure TSkiaCustomThreadedBase.StopThread;
begin
  if not Assigned(FThread) then Exit;

  FThread.Terminate;
  // Real wait instead of the old Sleep(100): the loop checks
  // CheckTerminated at least once per frame, so this returns quickly.
  // Safe here: TThread.Queue is non-blocking, and WaitFor called from
  // the main thread pumps queued calls - no deadlock.
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

procedure TSkiaCustomThreadedBase.ThreadSafeInvalidate;
begin
  if csDestroying in ComponentState then Exit;
  TThread.Queue(nil,
    procedure
    begin
      if not (csDestroying in ComponentState) and Assigned(Self) then
        Self.Redraw;
    end);
end;

procedure TSkiaCustomThreadedBase.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  ImageToDraw: ISkImage;
  CurrentTime: Double;
begin
  // 1. GRAB THE LATEST IMAGE
  FLock.Acquire;
  try
    ImageToDraw := FBackBuffer;
  finally
    FLock.Release;
  end;

  // 2. DRAW IT
  if Assigned(ImageToDraw) then
  begin
    // Simply draw the snapshot.
    // We use High quality sampling just in case of scaling,
    // though NearestNeighbor is faster if 1:1 pixel mapping.
    ACanvas.DrawImage(ImageToDraw, 0, 0, TSkSamplingOptions.High);

    // 3. REAL FPS MEASUREMENT
    //    We count frames that actually reach the screen here (UI thread).
    //    This is the true presentation rate, which may differ from
    //    TargetFPS due to thread scheduling, vsync, or main-thread load.
    Inc(FFrameCount);
    CurrentTime := FStopwatch.Elapsed.TotalMilliseconds;
    if (CurrentTime - FLastFpsTime) >= 1000 then
    begin
      FRealFPS := Round(FFrameCount / ((CurrentTime - FLastFpsTime) / 1000.0));
      FFrameCount := 0;
      FLastFpsTime := CurrentTime;
    end;
  end
  else
  begin
    // Fallback if thread hasn't started yet
    ACanvas.Clear(TAlphaColors.Black);
  end;
end;

{------------------------------------------------------------------------------
  DEMO MODE (Built-in visualization - Runs in Thread now!)
------------------------------------------------------------------------------}

procedure TSkiaCustomThreadedBase.UpdateLogic(const DeltaTime: Double);
var
  NewLeft, NewTop: Single;
begin
  // 1. Move Rectangle
  FDemoRect.Offset(FDemoVelocity.X * DeltaTime, FDemoVelocity.Y * DeltaTime);
  NewLeft := FDemoRect.Left;
  NewTop := FDemoRect.Top;

  if NewLeft < 0 then
  begin
    FDemoVelocity.X := Abs(FDemoVelocity.X);
    FDemoRect.Left := 0;
  end
  else if FDemoRect.Right > Width then
  begin
    FDemoVelocity.X := -Abs(FDemoVelocity.X);
    FDemoRect.Left := Width - FDemoRect.Width;
  end;

  if NewTop < 0 then
  begin
    FDemoVelocity.Y := Abs(FDemoVelocity.Y);
    FDemoRect.Top := 0;
  end
  else if FDemoRect.Bottom > Height then
  begin
    FDemoVelocity.Y := -Abs(FDemoVelocity.Y);
    FDemoRect.Top := Height - FDemoRect.Height;
  end;

  // 2. Animate the Pulse
  FAngle := FAngle + (3.0 * DeltaTime);
end;

procedure TSkiaCustomThreadedBase.RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double);
var
  Paint: ISkPaint;
  Font: ISkFont;
  Typeface: ISkTypeface;
  PulseFactor: Single;
  GVal: Integer;
  CurrentColor: TAlphaColor;
begin
  if not FActive then
  begin
    // Draw "Paused" state
    Paint := TSkPaint.Create;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := $FF1E1E1E;
    ACanvas.DrawRect(ADest, Paint);

    Typeface := TSkTypeface.MakeDefault;
    Font := TSkFont.Create(Typeface, 20);
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawSimpleText('Thread Active: Paused', 20, Height / 2, Font, Paint);
    ACanvas.DrawSimpleText('Set Active = True to Demo', 20, (Height / 2) + 30, Font, Paint);
  end
  else
  begin
    // 1. Pulse Math
    PulseFactor := (Sin(FAngle) + 1) / 2;

    // 2. Background
    Paint := TSkPaint.Create;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := $FF000000;
    ACanvas.DrawRect(ADest, Paint);

    // 3. Pulsing Rect
    GVal := Round(255 * PulseFactor);
    CurrentColor := $FF000000 or (GVal shl 8) or $000000FF;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := CurrentColor;
    Paint.AlphaF := 0.8 + (0.2 * PulseFactor);
    Paint.ImageFilter := TSkImageFilter.MakeBlur(10 + (10 * PulseFactor), 10 + (10 * PulseFactor));
    ACanvas.DrawRect(FDemoRect, Paint);

    // 4. Border
    Paint.Style := TSkPaintStyle.Stroke;
    Paint.StrokeWidth := 2;
    Paint.Color := TAlphaColors.White;
    Paint.ImageFilter := nil;
    ACanvas.DrawRect(FDemoRect, Paint);
  end;
end;

procedure TSkiaCustomThreadedBase.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FActive then
    begin
      if not FThreadActive then
        StartThread;
      FPaused := False;
    end
    else
    begin
      FPaused := True;
    end;
    ThreadSafeInvalidate;
  end;
end;

procedure TSkiaCustomThreadedBase.SetTargetFPS(const Value: Integer);
begin
  if FTargetFPS <> Value then
    FTargetFPS := Value;
end;

end.
