unit Unit1;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls,
  SkiaPageControl;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    FSkiaPages: TSkiaPageControl;
    FPage1, FPage2, FPage3: TPanel;
    FEffectCombo: TComboBox;
    procedure CreateUI;
    procedure OnPageChange(Sender: TObject; NewIndex: Integer);
    procedure OnEffectChange(Sender: TObject);
  public
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

procedure TForm1.FormCreate(Sender: TObject);
begin
  DoubleBuffered := True;
  CreateUI;
end;

procedure TForm1.CreateUI;
var
  LBtn: TButton;
  LPnl: TPanel;
  LLabel: TLabel;
begin
  ClientWidth := 600;
  ClientHeight := 400;
  Position := poScreenCenter;
  Caption := 'Pro Skia PageControl';

  // 1. Create our PageControl
  FSkiaPages := TSkiaPageControl.Create(Self);
  FSkiaPages.Parent := Self;
  FSkiaPages.Align := alClient;
  FSkiaPages.Effect := cePageblur;
  FSkiaPages.OnChange := OnPageChange;

  // 2. Create Effect Selector (ComboBox) on top of the PageControl
  FEffectCombo := TComboBox.Create(Self);
  FEffectCombo.Parent := Self; // Parent to Form, so it floats above the control
  FEffectCombo.SetBounds(200, 2, 150, 25);
  FEffectCombo.Style := csDropDownList;
  // Add items matching the enum order
  FEffectCombo.Items.Add('None');
  FEffectCombo.Items.Add('Slide Left');
  FEffectCombo.Items.Add('Page Blur');
  FEffectCombo.ItemIndex := 2; // Select 'Page Blur' by default
  FEffectCombo.OnChange := OnEffectChange;

  // 3. Create Page 1 (Red)
  FPage1 := TPanel.Create(Self);
  FPage1.Name := 'pgSettings';
  FPage1.Color := $00402020;
  FPage1.Parent := FSkiaPages;
  FSkiaPages.AddPage(FPage1);

  LLabel := TLabel.Create(FPage1);
  LLabel.Parent := FPage1;
  LLabel.Caption := 'Settings Page';
  LLabel.Font.Color := clWhite;
  LLabel.Font.Size := 20;
  LLabel.SetBounds(20, 20, 200, 50);

  // 4. Create Page 2 (Blue)
  FPage2 := TPanel.Create(Self);
  FPage2.Name := 'pgData';
  FPage2.Color := $00202040;
  FPage2.Parent := FSkiaPages;
  FSkiaPages.AddPage(FPage2);

  LLabel := TLabel.Create(FPage2);
  LLabel.Parent := FPage2;
  LLabel.Caption := 'Data Page';
  LLabel.Font.Color := clWhite;
  LLabel.Font.Size := 20;
  LLabel.SetBounds(20, 20, 200, 50);

  // 5. Create Page 3 (Green)
  FPage3 := TPanel.Create(Self);
  FPage3.Name := 'pgAbout';
  FPage3.Color := $00204020;
  FPage3.Parent := FSkiaPages;
  FSkiaPages.AddPage(FPage3);

  LLabel := TLabel.Create(FPage3);
  LLabel.Parent := FPage3;
  LLabel.Caption := 'About Page';
  LLabel.Font.Color := clWhite;
  LLabel.Font.Size := 20;
  LLabel.SetBounds(20, 20, 200, 50);
end;

procedure TForm1.OnPageChange(Sender: TObject; NewIndex: Integer);
begin
  Caption := 'Active Page Index: ' + IntToStr(NewIndex);
end;

procedure TForm1.OnEffectChange(Sender: TObject);
begin
  if Assigned(FEffectCombo) then
  begin
    case FEffectCombo.ItemIndex of
      0: FSkiaPages.Effect := ceNone;
      1: FSkiaPages.Effect := ceSlideLeft;
      2: FSkiaPages.Effect := cePageblur;
    end;
  end;
end;

end.
