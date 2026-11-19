program Project1;

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Skia,
  Unit1 in 'Unit1.pas' {Form1},
  uGPUParticlePageControl in 'uGPUParticlePageControl.pas',
  uSkiaCustomThreadedBase in 'uSkiaCustomThreadedBase.pas';

{$R *.res}

begin
  GlobalUseSkia := True;
  Application.Initialize;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
