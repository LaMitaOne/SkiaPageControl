{*******************************************************************************
  uGPUParticlePageControl
********************************************************************************
  GPU-particle page-transition control. Built on the exact same architecture
  as uSkiaGPULiquid (TSkiaCustomThreadedBase derivative with an offscreen
  OpenGL 4.3 Core context inside the render thread), but instead of a free
  curl-noise fluid field this one morphs ONE captured page image into the
  NEXT captured page image.

  The transition works like this:
    - Every output pixel of the transition surface is one particle.
    - Each particle is lazily seeded on the GPU (first frame after a
      transition starts) by sampling its start position in texOld and its
      target position in texNew. So particle N starts at "where its color
      came from in the OLD image" and flies to "where its color lands in the
      NEW image". Both the position AND the color are picked up from the two
      source textures - no CPU seeding loop, no host upload of per-particle
      data, exactly like the Liquid's lazy pcgHash init.
    - During the transition the particle moves along a quadratic Bezier
      (pos0 -> radial outward control point -> pos1) with a per-particle
      sin() wobble added so the cloud does not look like one rigid block.
      Color is faded independently with smoothstep - "color schoen langsam
      faden bei jedem einzelnen".
    - When the transition is done (progress >= 1) the SSBO is invalidated
      by setting a per-particle "seeded" flag back to 0, so the next
      transition re-seeds from the new pair of textures.

  Storage layout: 32 bytes per particle, packed as a std430 struct with
  two uvec4 fields (pos, extra). I spell the field layout out here in
  words instead of as GLSL, because a C-style struct closing brace inside
  a Pascal block comment would terminate the comment prematurely:
    pos.xy   = packed half2  start UV (pos0)
    pos.zw   = packed half2  target UV (pos1)
    extra.x  = packed half2  wobble phase + wobble amplitude
    extra.y  = uint flags         bit 0 = seeded
    extra.zw = reserved (keep std430 alignment nice; cheap)
  The matching GLSL declaration is in the TRANSITION_SHADER_SRC constant
  below - same fields, same order, same std430 layout.
  32B is twice the Liquid's 8B, but we run ONE particle per output pixel
  (not millions of free particles), so at 800x600 that is 480k * 32B = ~15MB
  VRAM - completely fine on any GPU.

  Author:  Lara Miriam Tamy Reschke / LaMitaOne
*******************************************************************************}

unit uGPUParticlePageControl;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.UITypes,
  System.SyncObjs, Winapi.Windows, FMX.Types, FMX.Controls, FMX.Skia,
  System.Skia, uSkiaCustomThreadedBase;

type
  TTransitionCompleteEvent = procedure(Sender: TObject) of object;

  TGPUParticlePageControl = class(TSkiaCustomThreadedBase)
  private
    FDummyWnd: HWND;
    FDummyDC: HDC;
    FGLContext: HGLRC;
    FGLInitialized: Boolean;
    FGLFailed: Boolean;
    FErrorMsg: string;

    FComputeProgram: Cardinal;
    FFadeProgram: Cardinal;
    FSSBO_Particles: Cardinal;
    FOutputTex: Cardinal;
    FInputTexOld: Cardinal;
    FInputTexNew: Cardinal;
    FInputTexOldW: Integer;
    FInputTexOldH: Integer;
    FInputTexNewW: Integer;
    FInputTexNewH: Integer;
    FInputDirtyOld: Boolean;
    FInputDirtyNew: Boolean;
    FPendingOld: TBytes;
    FPendingOldW: Integer;
    FPendingOldH: Integer;
    FPendingNew: TBytes;
    FPendingNewW: Integer;
    FPendingNewH: Integer;

    FTexWidth: Integer;
    FTexHeight: Integer;
    FPixelBuffer: TBytes;

    FParticleCount: Int64;

    // PBO ping-pong for async glGetTexImage (GPU->RAM transfer overlaps
    // with next frame's compute work; removes the pipeline stall).
    FPBOs: array[0..1] of Cardinal;
    FPBOSize: NativeInt;
    FPBOIndex: Integer;
    FPBOHasData: Boolean;

    FLoc_Progress: Integer;
    FLoc_Resolution: Integer;
    FLoc_ParticleCount: Integer;
    FLoc_WobbleStrength: Integer;
    FLocFade_Resolution: Integer;
    FLocFade_Decay: Integer;

    FParamLock: TCriticalSection;

    // Transition state (set on the main thread, consumed on the GL thread).
    FProgress: Single;          // 0..1, advanced in UpdateLogic.
    FTransitioning: Boolean;
    FDuration: Single;          // seconds, e.g. 1.2
    FWobbleStrength: Single;   // 0..1, how strong the sin wobble is.
    FTrailDecay: Single;        // background fade per frame (Liquid-style).
    FNeedReseed: Boolean;       // set by StartTransition; DispatchTransition zeroes the SSBO seed-flags.
    FNeedOutputPrefill: Boolean; // set by StartTransition; UploadPendingInputs
                                //   copies the OLD page pixels into FOutputTex
                                //   once so the fade-pass trail-decay starts
                                //   from the old page instead of black.

    FGPUFrameCount: Integer;
    FGPULastTime: Double;
    FGPURealFPS: Integer;
    FOnTransitionComplete: TTransitionCompleteEvent;
    FCompletePending: Boolean;   // set on GL thread, fired via TThread.Queue on main
    FLastSimW: Integer;         // last sim size used by DispatchTransition, so
    FLastSimH: Integer;         //   the idle blit knows the pixel buffer pitch.
    FPreviewFramesLeft: Integer; // set to 2 by StartTransition; RenderEffect
                                 //   shows the cached FStartPreview for that
                                 //   many frames instead of the stale or
                                 //   empty FPixelBuffer. We need TWO preview
                                 //   frames because of the PBO ping-pong:
                                 //   Frame 1: PBOHasData is False, no readback,
                                 //     FPixelBuffer is still black from init.
                                 //   Frame 2: readback of PBO[0] begins, but
                                 //     glGetTexImage is ASYNC - the DMA may not
                                 //     have finished yet, so glMapBufferRange
                                 //     returns the previous content (still 0).
                                 //   Frame 3: readback of PBO[1] returns the
                                 //     real first frame. Only now can we
                                 //     safely blit FPixelBuffer.
    FStartPreview: ISkImage;    // snapshot of the OLD page captured in
    FStartPreviewBytes: TBytes; //   SetImageOld. Held for the lifetime of the
                                //   image so MakeFromRaster's pointer stays
                                //   valid; released when SetImageOld replaces
                                //   it or the component is destroyed.

    function InitOffscreenGL: Boolean;
    procedure CleanupOffscreenGL;
    procedure EnsureOutputTexture(W, H: Integer);
    procedure InitParticles(ACount: Int64);
    procedure UploadPendingInputs(PrefillOutput: Boolean);
    procedure DispatchTransition(const ATime, ADeltaTime: Double; ViewW, ViewH, SimW, SimH: Integer);
    function GetRealFPS: Integer;
  protected
    procedure UpdateLogic(const DeltaTime: Double); override;
    procedure RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Push a BGRA8 buffer (row-major, bottom-up like glGetTexImage) as the
      OLD or NEW input texture. Called from the main thread; the actual
      glTexSubImage2D upload happens later on the GL thread (UploadPendingInputs)
      because a GL context is only current there. }
    procedure SetImageOld(const ABGRA: TBytes; AW, AH: Integer);
    procedure SetImageNew(const ABGRA: TBytes; AW, AH: Integer);

    { Kick off a transition. Re-seeds lazily on the GPU from the currently
      set OLD/NEW textures, advances progress in UpdateLogic, stops at 1.0. }
    procedure StartTransition(ADurationSec: Single = 1.2);

    property RealFPS: Integer read GetRealFPS;
    property WobbleStrength: Single read FWobbleStrength write FWobbleStrength;
    property TrailDecay: Single read FTrailDecay write FTrailDecay;
    property IsTransitioning: Boolean read FTransitioning;
    property Progress: Single read FProgress;
    { Fires on the MAIN thread when progress reaches 1.0. The host uses this
      to hide its overlay and reveal the new page panel. We marshal from
      the GL thread to the UI thread via TThread.Queue so the handler can
      safely touch VCL/FMX controls. }
    property OnTransitionComplete: TTransitionCompleteEvent read FOnTransitionComplete write FOnTransitionComplete;
  end;

implementation

const
  { OpenGL constants - same set as uSkiaGPULiquid, so we share the same
    bare-minimum 4.3 compute surface without dragging in dglOpenGL. }
  GL_COMPUTE_SHADER = $91B9;
  GL_COMPILE_STATUS = $8B81;
  GL_LINK_STATUS = $8B82;
  GL_SHADER_IMAGE_ACCESS_BARRIER_BIT = $0020;
  GL_SHADER_STORAGE_BARRIER_BIT = $2000;
  GL_TEXTURE_FETCH_BARRIER_BIT = $0008;
  GL_FALSE = 0;
  GL_SHADER_STORAGE_BUFFER = $90D2;
  GL_DYNAMIC_COPY = $88EA;
  GL_TEXTURE_2D = $0DE1;
  GL_RGBA8 = $8058;
  GL_BGRA = $80E1;
  GL_UNSIGNED_BYTE = $1401;
  GL_LINEAR = $2601;
  GL_NEAREST = $2600;
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_TEXTURE_WRAP_S = $2802;
  GL_TEXTURE_WRAP_T = $2803;
  GL_CLAMP_TO_EDGE = $812F;
  GL_TEXTURE0 = $84C0;
  GL_R32UI = $8234;
  GL_RED_INTEGER = $8D94;
  GL_UNSIGNED_INT = $1405;
  GL_STATIC_COPY = $88E6;
  GL_READ_WRITE = $88BA;
  GL_PIXEL_PACK_BUFFER          = $88EB;
  GL_STREAM_READ                = $88E1;
  GL_MAP_READ_BIT              = $0001;
  WGL_CONTEXT_MAJOR_VERSION_ARB = $2091;
  WGL_CONTEXT_MINOR_VERSION_ARB = $2092;
  WGL_CONTEXT_PROFILE_MASK_ARB = $9126;
  WGL_CONTEXT_CORE_PROFILE_BIT_ARB = $00000001;
  GL43_ATTRIBS: array[0..6] of Integer = (WGL_CONTEXT_MAJOR_VERSION_ARB, 4, WGL_CONTEXT_MINOR_VERSION_ARB, 3, WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB, 0);

type
  PFNWGLCREATECONTEXTATTRIBSARBPROC = function(hDC: HDC; hShareContext: HGLRC; const attribList: PInteger): HGLRC; stdcall;
  PFNGLCREATESHADERPROC = function(shaderType: Cardinal): Cardinal; stdcall;
  PFNGLSHADERSOURCEPROC = procedure(shader: Cardinal; count: Integer; str: PPAnsiChar; len: PInteger); stdcall;
  PFNGLCOMPILESHADERPROC = procedure(shader: Cardinal); stdcall;
  PFNGLDELETESHADERPROC = procedure(shader: Cardinal); stdcall;
  PFNGLGETSHADERIVPROC = procedure(shader: Cardinal; pname: Cardinal; params: PInteger); stdcall;
  PFNGLGETSHADERINFOLOGPROC = procedure(shader: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLCREATEPROGRAMPROC = function: Cardinal; stdcall;
  PFNGLATTACHSHADERPROC = procedure(programObj: Cardinal; shader: Cardinal); stdcall;
  PFNGLLINKPROGRAMPROC = procedure(programObj: Cardinal); stdcall;
  PFNGLDELETEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;
  PFNGLGETPROGRAMIVPROC = procedure(programObj: Cardinal; pname: Cardinal; params: PInteger); stdcall;
  PFNGLGETPROGRAMINFOLOGPROC = procedure(programObj: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLUSEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;
  PFNGLGETUNIFORMLOCATIONPROC = function(programObj: Cardinal; name: PAnsiChar): Integer; stdcall;
  PFNGLUNIFORM1FPROC = procedure(location: Integer; v: Single); stdcall;
  PFNGLUNIFORM2FPROC = procedure(location: Integer; x: Single; y: Single); stdcall;
  PFNGLUNIFORM1IPROC = procedure(location: Integer; v: Integer); stdcall;
  PFNGLUNIFORM1UIPROC = procedure(location: Integer; v: Cardinal); stdcall;
  PFNGLCLEARBUFFERDATAPROC = procedure(target: Cardinal; internalformat: Cardinal; format: Cardinal; type_: Cardinal; data: Pointer); stdcall;
  PFNGLDISPATCHCOMPUTEPROC = procedure(num_groups_x, num_groups_y, num_groups_z: Cardinal); stdcall;
  PFNGLMEMORYBARRIERPROC = procedure(barriers: Cardinal); stdcall;
  PFNGLGENBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLDELETEBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLBINDBUFFERPROC = procedure(target: Cardinal; buffer: Cardinal); stdcall;
  PFNGLBUFFERDATAPROC = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;
  PFNGLBINDBUFFERBASEPROC = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;
  PFNGLMAPBUFFERRANGEPROC = function(target: Cardinal; offset: NativeInt; length: NativeInt; access: Cardinal): Pointer; stdcall;
  PFNGLUNMAPBUFFERPROC = function(target: Cardinal): ByteBool; stdcall;
  PFNGLTEXSTORAGE2DPROC = procedure(target: Cardinal; levels: Integer; internalformat: Cardinal; width, height: Integer); stdcall;
  PFNGLBINDIMAGETEXTUREPROC = procedure(unit_: Cardinal; texture: Cardinal; level: Integer; layered: Byte; layer: Integer; access: Cardinal; format: Cardinal); stdcall;
  PFNGLTEXSUBIMAGE2DPROC = procedure(target: Cardinal; level, xoffset, yoffset, width, height: Integer; format, type_: Cardinal; const pixels); stdcall;
  PFNGLACTIVETEXTUREPROC = procedure(texture: Cardinal); stdcall;

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';
function wglCreateContext(hdc: hdc): HGLRC; stdcall; external 'opengl32.dll';
function wglDeleteContext(hglrc: hglrc): BOOL; stdcall; external 'opengl32.dll';
function wglMakeCurrent(hdc: hdc; hglrc: hglrc): BOOL; stdcall; external 'opengl32.dll';

procedure glGenTextures(n: Integer; textures: PCardinal); stdcall; external 'opengl32.dll';
procedure glDeleteTextures(n: Integer; textures: PCardinal); stdcall; external 'opengl32.dll';
procedure glBindTexture(target: Cardinal; texture: Cardinal); stdcall; external 'opengl32.dll';
procedure glTexParameteri(target: Cardinal; pname: Cardinal; param: Integer); stdcall; external 'opengl32.dll';
procedure glGetTexImage(target: Cardinal; level: Integer; format: Cardinal; type_: Cardinal; pixels: Pointer); stdcall; external 'opengl32.dll';

var
  glCreateShader: PFNGLCREATESHADERPROC;
  glShaderSource: PFNGLSHADERSOURCEPROC;
  glCompileShader: PFNGLCOMPILESHADERPROC;
  glDeleteShader: PFNGLDELETESHADERPROC;
  glGetShaderiv: PFNGLGETSHADERIVPROC;
  glGetShaderInfoLog: PFNGLGETSHADERINFOLOGPROC;
  glCreateProgram: PFNGLCREATEPROGRAMPROC;
  glAttachShader: PFNGLATTACHSHADERPROC;
  glLinkProgram: PFNGLLINKPROGRAMPROC;
  glDeleteProgram: PFNGLDELETEPROGRAMPROC;
  glGetProgramiv: PFNGLGETPROGRAMIVPROC;
  glGetProgramInfoLog: PFNGLGETPROGRAMINFOLOGPROC;
  glUseProgram: PFNGLUSEPROGRAMPROC;
  glGetUniformLocation: PFNGLGETUNIFORMLOCATIONPROC;
  glUniform1f: PFNGLUNIFORM1FPROC;
  glUniform2f: PFNGLUNIFORM2FPROC;
  glUniform1i: PFNGLUNIFORM1IPROC;
  glUniform1ui: PFNGLUNIFORM1UIPROC;
  glClearBufferData: PFNGLCLEARBUFFERDATAPROC;
  glDispatchCompute: PFNGLDISPATCHCOMPUTEPROC;
  glMemoryBarrier: PFNGLMEMORYBARRIERPROC;
  glGenBuffers: PFNGLGENBUFFERSPROC;
  glDeleteBuffers: PFNGLDELETEBUFFERSPROC;
  glBindBuffer: PFNGLBINDBUFFERPROC;
  glBufferData: PFNGLBUFFERDATAPROC;
  glMapBufferRange: PFNGLMAPBUFFERRANGEPROC;
  glUnmapBuffer: PFNGLUNMAPBUFFERPROC;
  glBindBufferBase: PFNGLBINDBUFFERBASEPROC;
  glTexStorage2D: PFNGLTEXSTORAGE2DPROC;
  glBindImageTexture: PFNGLBINDIMAGETEXTUREPROC;
  glTexSubImage2D: PFNGLTEXSUBIMAGE2DPROC;
  glActiveTexture: PFNGLACTIVETEXTUREPROC;

{ Fade pass - decays the previous frame's RGBA8 image so trails fade out
  smoothly between dispatches. Same shader as the Liquid uses, just reused. }
const
  FADE_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'layout(local_size_x = 16, local_size_y = 16) in;'#10 +
    'layout(rgba8, binding = 0) uniform image2D imgOut;'#10 +
    'uniform vec2 resolution;'#10 +
    'uniform float decay;'#10 +
    'void main() {'#10 +
    '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 +
    '  if (px.x >= int(resolution.x) || px.y >= int(resolution.y)) return;'#10 +
    '  vec4 col = imageLoad(imgOut, px);'#10 +
    '  col.rgb *= decay;'#10 +
    '  col.a = 1.0;'#10 +
    '  imageStore(imgOut, px, col);'#10 +
    '}';

{ The actual transition compute shader.

  Per-particle storage is 32 bytes (a uvec4 pos + a uvec4 extra) packed as a
  std430 struct, so layout alignment is automatic and the two fields of one
  particle always live at offset idx*32 and idx*32+16:
    pos.xy   = packed half2  startUV   (pos0)
    pos.zw   = packed half2  targetUV  (pos1)
    extra.x  = packed half2  wobblePhase + wobbleAmp (random per particle)
    extra.y  = uint flags         bit 0 = seeded
    extra.zw = reserved

  Why lazy GPU seeding instead of CPU upload:
  CPU seeding means uploading W*H floats to the GPU per transition. At
  800x600 that is 480k particles * 32B = 15MB - not bad, but the upload
  still costs a full glBufferSubData with a host->device copy. The Liquid
  already solved this by seeding positions procedurally on the GPU on the
  first frame after a resize. We do exactly the same: the first frame of
  a transition samples both input textures and writes the start/target
  UVs into the SSBO. From frame 2 onwards we just read the cached values.

  Particle motion: COHERENT VORTEX around the screen center.
    Every particle rotates around (0.5, 0.5) in the SAME direction, so the
    whole cloud looks like a swirling galaxy arm rather than chaotic noise.
    The motion is composed of:
      a) radial expansion outward (sin(p*pi) envelope, peaks at p=0.5)
         with a per-particle jitter so neighbors do not all stop at the
         same radius - this is what kills the regular 5px stripes that
         appeared when neighbors all reached the same Bezier midpoint.
      b) tangential rotation around the screen center (sin(p*pi) envelope),
         coherent for every particle (derived from pos0, not random).
      c) tiny per-particle flutter (wAmp * 0.3, much smaller than before)
         just to break the last bit of lock-step without dominating.
    All three are scaled by sin(p*pi), so bezPos == pos0 at p=0 and bezPos
    == pos1 at p=1 - clean start and clean landing frames.

  NanoFog / Materialize upgrades (kept fully host-compatible - no new
  uniforms; SSBO extra.z is now used for the radial jitter, was 0 before):
    1. Staggered Wave Launch: each particle has a per-coordinate launch
       delay = clamp(pos0.x*0.35 + pos0.y*0.25 + hash*0.25, 0, 0.45).
       Local progress is remapped (p - delay) / (1 - delay), clamped to
       [0,1]. Pixels peel off in an organic wave instead of all at once.
       EVERY pixel of the page flies - we deliberately do NOT cull
       unchanged background pixels, because that left "holes" in the cloud
       when two pages shared the same background color.
    2. Mid-Flight Glow: at the peak of local progress (sin(localP*pi)),
       boost particle color additively by a cool blue-cyan energy tint
       (+ vec3(0.35,0.65,1.0) * peak * 0.8) so particles glow like sparks
       while swirling, then cross-fade back to the destination color.
    3. Coherent Vortex: replaces the previous per-particle random curl +
       wobble (which produced "planlos" flying with visible stripes).
       All particles share one rotation direction -> visible swirl flow.

  Color: linear blend of texOld(pos0) -> texNew(pos1) over smoothstep(0,1,p)
  PLUS the mid-flight energy boost. }
const
  TRANSITION_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'layout(local_size_x = 16, local_size_y = 16) in;'#10 +
    'struct Particle {'#10 +
    '  uvec4 pos;'#10 +
    '  uvec4 extra;'#10 +
    '};'#10 +
    'layout(std430, binding = 0) buffer Particles {'#10 +
    '  Particle particles[];'#10 +
    '};'#10 +
    'layout(rgba8, binding = 0) uniform image2D imgOut;'#10 +
    'layout(binding = 1) uniform sampler2D texOld;'#10 +
    'layout(binding = 2) uniform sampler2D texNew;'#10 +
    'uniform vec2  resolution;'#10 +
    'uniform float progress;'#10 +
    'uniform float wobbleStrength;'#10 +
    'uniform uint  particleCount;'#10 +
    #10 +
    'uint pcgHash(uint s) {'#10 +
    '  s = s * 747796405u + 2891336453u;'#10 +
    '  uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;'#10 +
    '  return (w >> 22u) ^ w;'#10 +
    '}'#10 +
    'float rand01(uint s) { return float(pcgHash(s)) / 4294967295.0; }'#10 +
    #10 +
    'void main() {'#10 +
    '  uint idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 16u) + gl_GlobalInvocationID.x;'#10 +
    '  if (idx >= particleCount) return;'#10 +
    #10 +
    // Lazy seeding: zero SSBO is detected via the seeded flag in extra.y.
    // On the first frame of a transition we pick the particle's start UV
    // (where in the OLD image this particle's color comes from) and target
    // UV (where in the NEW image it should land). Both are derived from
    // the particle's own index mapped into the resolution - so particle N
    // starts at the pixel it represents in the old image, and ends at the
    // pixel it represents in the new image. We also generate a per-particle
    // wobble phase + amplitude.
    '  uint seeded = particles[idx].extra.y;'#10 +
    '  if ((seeded & 1u) == 0u) {'#10 +
    '    vec2 uv = vec2((idx % uint(resolution.x)) + 0.5,'#10 +
    '                  (idx / uint(resolution.x)) + 0.5) / resolution;'#10 +
    '    particles[idx].pos = uvec4(packHalf2x16(uv), packHalf2x16(uv), 0u, 0u);'#10 +
    '    float phase  = rand01(idx * 3u + 1u) * 6.2831;'#10 +
    '    float amp    = 0.02 + rand01(idx * 3u + 2u) * 0.10;'#10 +
    // extra.z: a small radial jitter (0..1) used to push each particle a
    // different distance outward during the vortex flight. Without this,
    // particles on the same pixel row all reach the same radius at the same
    // time and form visible horizontal/vertical "stripes" during the
    // explosion phase. The jitter desynchronizes the radial distance so
    // neighbors spread out into a continuous cloud instead of staying on
    // a regular lattice. extra.y stays as the seeded-flag (bit 0).
    '    float radJit = rand01(idx * 11u + 7u);'#10 +
    '    particles[idx].extra = uvec4(packHalf2x16(vec2(phase, amp)),'#10 +
    '                                1u,'#10 +
    '                                packHalf2x16(vec2(radJit, 0.0)),'#10 +
    '                                0u);'#10 +
    // No return: fall through and draw THIS frame too. Each invocation
    // reads back its own SSBO slot just written above; same-index
    // read-after-write inside one invocation is always safe in GLSL.
    // At progress=0 this yields bezPos = pos0 and color = texOld(pos0) -
    // i.e. the first visible frame of the transition shows the OLD image
    // exactly where it was, no blank or faded skip-frame.
    '  }'#10 +
    #10 +
    '  vec2 pos0 = unpackHalf2x16(particles[idx].pos.x);'#10 +
    '  vec2 pos1 = unpackHalf2x16(particles[idx].pos.y);'#10 +
    '  vec2 wob   = unpackHalf2x16(particles[idx].extra.x);'#10 +
    '  float wPhase = wob.x;'#10 +
    '  float wAmp   = wob.y * wobbleStrength;'#10 +
    '  vec2 radJitV = unpackHalf2x16(particles[idx].extra.z);'#10 +
    '  float radJit = radJitV.x;'#10 +
    #10 +
    // Sample source + destination color ONCE. We need both for the
    // mid-flight glow boost and the cross-fade.
    '  vec4 cOld = texture(texOld, pos0);'#10 +
    '  vec4 cNew = texture(texNew, pos1);'#10 +
    #10 +
    // ---- (1) Staggered Wave Launch -------------------------------------
    // Per-particle launch delay based on the pixel's position in the old
    // image plus a hash noise term. Pixels peel off in an organic wave
    // (top-left first, bottom-right later, jittered) instead of all at the
    // exact same millisecond. Local progress is remapped so each particle
    // spends (1 - delay) of the global timeline actually flying.
    '  float hash = rand01(idx * 7u + 5u);'#10 +
    '  float delay = clamp(pos0.x * 0.35 + pos0.y * 0.25 + hash * 0.25, 0.0, 0.45);'#10 +
    '  float localP = clamp((progress - delay) / max(1.0 - delay, 0.001), 0.0, 1.0);'#10 +
    '  float p = localP;'#10 +
    #10 +
    // ---- (2) Coherent Vortex motion -------------------------------------
    // Instead of a per-particle random wobble (which made the cloud look
    // "planlos" - particles flying every direction at once with no visible
    // flow, and forming regular 5px stripes because neighbors all reached
    // the same Bezier midpoint at the same time), we now rotate every
    // particle coherently around the SCREEN CENTER. This produces a visible
    // "swirl" - like a galaxy arm - while still collapsing cleanly onto
    // pos1 at p=1.
    //
    // The motion is composed of three parts:
    //   a) Radial expansion outward (sin(p*pi) envelope, peaks at p=0.5).
    //      Particles fly outward, then come back. The expansion amount is
    //      jittered per-particle (radJit) so neighbors do not all stop at
    //      the same radius and form stripes - they spread into a cloud.
    //   b) Tangential rotation (also sin(p*pi) envelope). Particles orbit
    //      the center; the rotation direction is the SAME for every particle
    //      (derived from pos0, not from wPhase), so the whole cloud rotates
    //      as one coherent swirl instead of chaotically.
    //   c) Smooth ease back to pos1 (Bezier blend) so particles land
    //      exactly on their target pixel at p=1.
    //
    // At p=0 and p=1 the sin envelopes are 0, so bezPos == pos0 (start) and
    // bezPos == pos1 (end). At p=0.5 the cloud is fully expanded and rotated.
    '  vec2  fromCenter = pos0 - vec2(0.5);'#10 +
    '  float dist        = length(fromCenter) + 0.0001;'#10 +
    '  vec2  radOut      = fromCenter / dist;'#10 +
    '  vec2  tangent     = vec2(-radOut.y, radOut.x);'#10 +
    #10 +
    // Expansion: outward push, scaled by per-particle jitter (0.4..1.0) so
    // neighbors land at different radii - this is the key stripe-killer.
    '  float expAmt = sin(p * 3.14159) * (0.10 + radJit * 0.22);'#10 +
    '  vec2  expOff = radOut * expAmt;'#10 +
    #10 +
    // Rotation: coherent tangential swirl. The base rotation is the SAME for
    // every particle (derived from p, not from wPhase), so the whole cloud
    // rotates as one coherent vortex. wPhase only adds a SMALL per-particle
    // amplitude variation (also scaled by sin(p*pi) so it is exactly 0 at
    // the start and end - critical: without that scaling, particles would
    // have a non-zero offset at p=0 and the start frame would be wrong).
    '  float rotBase = sin(p * 3.14159) * 0.55;'#10 +
    '  float rotVar  = sin(p * 3.14159) * (wPhase - 3.1415) * 0.05;'#10 +
    '  float rotAng  = rotBase + rotVar;'#10 +
    '  vec2  rotOff = tangent * sin(rotAng) * dist * 1.2;'#10 +
    #10 +
    // Bezier-style blend from pos0 (start) toward pos1 (end), then apply
    // the expansion + rotation on top. At p=0 we get pure pos0; at p=1 we
    // get pure pos1; in between we get a smooth Bezier curve with the
    // vortex offsets added on top.
    '  vec2  bezPos = mix(pos0, pos1, p) + expOff + rotOff;'#10 +
    #10 +
    // Tiny per-particle flutter: a very small wobble (much smaller than the
    // old random wobble) just to break the last bit of lock-step without
    // killing the coherent swirl. wAmp here is small (0.02..0.12) and scaled
    // further down so it never dominates.
    '  float wobCur = sin(p * 3.14159) * wAmp * 0.3;'#10 +
    '  bezPos += vec2(sin(wPhase + p * 6.28), cos(wPhase + p * 6.28)) * wobCur;'#10 +
    #10 +
    // ---- Color: cross-fade + (3) Mid-Flight Glow ------------------------
    // Base color: smoothstep cross-fade from cOld (source) to cNew (dest).
    // At the peak of the flight (sin(localP*pi)), boost the color
    // additively by a cool blue-cyan energy tint. This makes particles
    // glow like sparks while swirling, then settle back to the
    // destination color as they snap onto pos1.
    '  float cp = smoothstep(0.0, 1.0, p);'#10 +
    '  vec4 col  = mix(cOld, cNew, cp);'#10 +
    '  float peak = sin(p * 3.14159);'#10 +
    '  col.rgb += vec3(0.35, 0.65, 1.0) * peak * 0.8;'#10 +
    '  col.rgb = clamp(col.rgb, 0.0, 1.0);'#10 +
    #10 +
    '  ivec2 px = ivec2(bezPos * resolution);'#10 +
    '  if (px.x >= 0 && px.x < int(resolution.x) && px.y >= 0 && px.y < int(resolution.y)) {'#10 +
    '    imageStore(imgOut, px, vec4(col.rgb, 1.0));'#10 +
    '  }'#10 +
    '}';

function CompileComputeShader(const Src: AnsiString): Cardinal;
var
  Shader: Cardinal;
  P: PAnsiChar;
  L, Ok: Integer;
  Log: array[0..2047] of AnsiChar;
begin
  Shader := glCreateShader(GL_COMPUTE_SHADER);
  P := PAnsiChar(Src);
  L := Length(Src);
  glShaderSource(Shader, 1, @P, @L);
  glCompileShader(Shader);
  glGetShaderiv(Shader, GL_COMPILE_STATUS, @Ok);
  if Ok = GL_FALSE then
  begin
    FillChar(Log, SizeOf(Log), 0);
    glGetShaderInfoLog(Shader, SizeOf(Log), nil, Log);
    glDeleteShader(Shader);
    raise Exception.Create('Compute Compile Error: ' + string(Log));
  end;
  Result := glCreateProgram();
  glAttachShader(Result, Shader);
  glLinkProgram(Result);
  glDeleteShader(Shader);
  glGetProgramiv(Result, GL_LINK_STATUS, @Ok);
  if Ok = GL_FALSE then
  begin
    FillChar(Log, SizeOf(Log), 0);
    glGetProgramInfoLog(Result, SizeOf(Log), nil, Log);
    glDeleteProgram(Result);
    raise Exception.Create('Program Link Error: ' + string(Log));
  end;
end;

{ TGPUParticlePageControl }

constructor TGPUParticlePageControl.Create(AOwner: TComponent);
begin
  inherited;
  FParamLock := TCriticalSection.Create;
  FWobbleStrength := 1.0;
  FTrailDecay := 0.86;
  FDuration := 1.2;
  FProgress := 0.0;
  FTransitioning := False;
  FNeedReseed := False;
  FNeedOutputPrefill := False;
  FPreviewFramesLeft := 0;
  FGPUFrameCount := 0;
  FGPULastTime := 0;
  FGPURealFPS := 0;
  FPBOs[0] := 0;
  FPBOs[1] := 0;
  FPBOSize := 0;
  FPBOIndex := 0;
  FPBOHasData := False;
  FParticleCount := 0;
  FComputeProgram := 0;
  FFadeProgram := 0;
  FOutputTex := 0;
  FInputTexOld := 0;
  FInputTexNew := 0;
  FInputTexOldW := 0;
  FInputTexOldH := 0;
  FInputTexNewW := 0;
  FInputTexNewH := 0;
  FInputDirtyOld := False;
  FInputDirtyNew := False;
end;

destructor TGPUParticlePageControl.Destroy;
begin
  inherited;
  CleanupOffscreenGL;
  FParamLock.Free;
end;

function TGPUParticlePageControl.GetRealFPS: Integer;
begin
  if Active and (FGPURealFPS > 0) then
    Result := FGPURealFPS
  else
    Result := inherited RealFPS;
end;

procedure TGPUParticlePageControl.SetImageOld(const ABGRA: TBytes; AW, AH: Integer);
begin
  FParamLock.Acquire;
  try
    FPendingOld := Copy(ABGRA, 0, Length(ABGRA));
    FPendingOldW := AW;
    FPendingOldH := AH;
    FInputDirtyOld := True;
    // Cache a Skia raster image of the OLD page so RenderEffect can blit
    // this exact image during the first TWO frames of the next transition
    // (FPreviewFramesLeft > 0). Without this, the first two visible frames
    // of a new transition would show either black or the stale
    // FPixelBuffer from the PREVIOUS transition - both look like a
    // one-or-two-frame flicker right before the particle cloud starts to
    // move. We hold our own copy of the bytes (FStartPreviewBytes) because
    // the raster image only stores a pointer to the pixel data - it does
    // NOT copy the bytes. FPendingOld is replaced on the next SetImageOld,
    // which would invalidate the pointer if we used it directly.
    if (AW > 0) and (AH > 0) and (Length(ABGRA) >= AW * AH * 4) then
    begin
      FStartPreviewBytes := Copy(ABGRA, 0, Length(ABGRA));
      FStartPreview := TSkImage.MakeFromRaster(
        TSkImageInfo.Create(AW, AH, TSkColorType.BGRA8888, TSkAlphaType.Premul),
        Pointer(FStartPreviewBytes), AW * 4);
    end
    else
    begin
      FStartPreview := nil;
      FStartPreviewBytes := nil;
    end;
  finally
    FParamLock.Release;
  end;
end;

procedure TGPUParticlePageControl.SetImageNew(const ABGRA: TBytes; AW, AH: Integer);
begin
  FParamLock.Acquire;
  try
    FPendingNew := Copy(ABGRA, 0, Length(ABGRA));
    FPendingNewW := AW;
    FPendingNewH := AH;
    FInputDirtyNew := True;
  finally
    FParamLock.Release;
  end;
end;

procedure TGPUParticlePageControl.StartTransition(ADurationSec: Single = 1.2);
begin
  FParamLock.Acquire;
  try
    FDuration := ADurationSec;
    FProgress := 0.0;
    FTransitioning := True;
    // Mark the SSBO for re-seeding: DispatchTransition (which runs on the
    // GL thread, where a context is current) will glClearBufferData the
    // seed-flags to 0 so the shader's lazy-init branch re-runs against
    // the new pair of input textures. We cannot touch GL here.
    FNeedReseed := True;
    // Request a one-shot PRE-FILL of FOutputTex with the OLD page pixels
    // (executed in UploadPendingInputs on the GL thread). Without this,
    // FOutputTex starts the transition as black (zeroed by EnsureOutputTexture
    // or faded out by FFadeProgram from the previous run), and the fade-pass
    // multiplies 0 * 0.86 = 0, so the FIRST visible particles fly over a
    // pitch-black background instead of over the old page they came from.
    // Pre-filling makes the old page fade out organically while the
    // particles dissolve off it.
    FNeedOutputPrefill := True;
    // Drop any stale PBO readback from the previous transition. Without
    // this, the first RenderEffect iteration of the new transition would
    // blit the LAST frame of the previous transition into FPixelBuffer
    // (via the async-readback path in DispatchTransition), and if that
    // previous frame already showed the new page (because progress hit
    // 1.0), the user briefly saw the target image flash through behind
    // the new particle cloud. Resetting FPBOHasData means the first
    // DispatchTransition skips the async readback, so FPixelBuffer keeps
    // the freshly-computed first frame.
    FPBOHasData := False;
    // Show FStartPreview (snapshot of the old page) for TWO frames, not one.
    // Combined with the CPU-side prefill in UploadPendingInputs (which
    // synchronously copies POld into FPixelBuffer during frame 1's
    // DispatchTransition), this gives a fully race-free startup sequence:
    //
    //   Frame 1: DispatchTransition prefills FPixelBuffer = POld (CPU
    //     System.Move, synchronous, no DMA race). Then computes frame 1 and
    //     starts the async DMA into PBO[0]. RenderEffect shows FStartPreview
    //     (the same old page) - FPreviewFramesLeft 2 -> 1.
    //   Frame 2: DispatchTransition issues glMapBufferRange on PBO[0]. The
    //     DMA from frame 1 may or may not have completed (driver-dependent);
    //     it does not matter because RenderEffect still shows FStartPreview
    //     this frame - FPreviewFramesLeft 1 -> 0. Compute frame 2, start DMA
    //     into PBO[1].
    //   Frame 3: DispatchTransition issues glMapBufferRange on PBO[1]. The
    //     DMA from frame 2 has now had TWO full frames to complete - by the
    //     GL spec the readback is guaranteed to deliver real frame-2 data.
    //     RenderEffect finally blits FPixelBuffer, which now contains the
    //     real first computed frame (old page + first particles).
    //
    // The CPU-side prefill is the safety net: if for any reason the very
    // first blit of FPixelBuffer happens earlier than expected (e.g. a
    // future code change lowers FPreviewFramesLeft), FPixelBuffer will at
    // worst hold the old page rather than black.
    FPreviewFramesLeft := 2;
    // Make sure the render thread is actually running. Active is idempotent
    // (setting it to True when already True is a no-op in TSkiaCustomThreadedBase),
    // so no need to check anything first.
    if not Active then
      Active := True;
  finally
    FParamLock.Release;
  end;
end;

function TGPUParticlePageControl.InitOffscreenGL: Boolean;
var
  PFD: TPixelFormatDescriptor;
  PF: Integer;
  TempCtx: hglrc;
  wglCreateContextAttribsARB: PFNWGLCREATECONTEXTATTRIBSARBPROC;
begin
  if FGLInitialized then
    Exit(True);
  if FGLFailed then
    Exit(False);
  try
    FDummyWnd := CreateWindowEx(0, 'STATIC', 'GLParticlePageCtrlDummy', WS_POPUP, 0, 0, 16, 16, 0, 0, HInstance, nil);
    if FDummyWnd = 0 then
      raise Exception.Create('CreateWindowEx failed');
    FDummyDC := GetDC(FDummyWnd);
    FillChar(PFD, SizeOf(PFD), 0);
    PFD.nSize := SizeOf(PFD);
    PFD.nVersion := 1;
    PFD.dwFlags := PFD_DRAW_TO_WINDOW or PFD_SUPPORT_OPENGL or PFD_DOUBLEBUFFER;
    PFD.iPixelType := PFD_TYPE_RGBA;
    PFD.cColorBits := 32;
    PF := ChoosePixelFormat(FDummyDC, @PFD);
    SetPixelFormat(FDummyDC, PF, @PFD);
    TempCtx := wglCreateContext(FDummyDC);
    wglMakeCurrent(FDummyDC, TempCtx);
    wglCreateContextAttribsARB := wglGetProcAddress('wglCreateContextAttribsARB');
    if Assigned(wglCreateContextAttribsARB) then
    begin
      FGLContext := wglCreateContextAttribsARB(FDummyDC, 0, @GL43_ATTRIBS);
      wglMakeCurrent(0, 0);
      wglDeleteContext(TempCtx);
      wglMakeCurrent(FDummyDC, FGLContext);
    end
    else
      FGLContext := TempCtx;
    glCreateShader := wglGetProcAddress('glCreateShader');
    glShaderSource := wglGetProcAddress('glShaderSource');
    glCompileShader := wglGetProcAddress('glCompileShader');
    glDeleteShader := wglGetProcAddress('glDeleteShader');
    glGetShaderiv := wglGetProcAddress('glGetShaderiv');
    glGetShaderInfoLog := wglGetProcAddress('glGetShaderInfoLog');
    glCreateProgram := wglGetProcAddress('glCreateProgram');
    glAttachShader := wglGetProcAddress('glAttachShader');
    glLinkProgram := wglGetProcAddress('glLinkProgram');
    glDeleteProgram := wglGetProcAddress('glDeleteProgram');
    glGetProgramiv := wglGetProcAddress('glGetProgramiv');
    glGetProgramInfoLog := wglGetProcAddress('glGetProgramInfoLog');
    glUseProgram := wglGetProcAddress('glUseProgram');
    glGetUniformLocation := wglGetProcAddress('glGetUniformLocation');
    glUniform1f := wglGetProcAddress('glUniform1f');
    glUniform2f := wglGetProcAddress('glUniform2f');
    glUniform1i := wglGetProcAddress('glUniform1i');
    glDispatchCompute := wglGetProcAddress('glDispatchCompute');
    glMemoryBarrier := wglGetProcAddress('glMemoryBarrier');
    glGenBuffers := wglGetProcAddress('glGenBuffers');
    glDeleteBuffers := wglGetProcAddress('glDeleteBuffers');
    glBindBuffer := wglGetProcAddress('glBindBuffer');
    glBufferData := wglGetProcAddress('glBufferData');
    glMapBufferRange := wglGetProcAddress('glMapBufferRange');
    glUnmapBuffer := wglGetProcAddress('glUnmapBuffer');
    glBindBufferBase := wglGetProcAddress('glBindBufferBase');
    glTexStorage2D := wglGetProcAddress('glTexStorage2D');
    glBindImageTexture := wglGetProcAddress('glBindImageTexture');
    glUniform1ui := wglGetProcAddress('glUniform1ui');
    glClearBufferData := wglGetProcAddress('glClearBufferData');
    glTexSubImage2D := wglGetProcAddress('glTexSubImage2D');
    glActiveTexture := wglGetProcAddress('glActiveTexture');
    if not Assigned(glActiveTexture) then
      glActiveTexture := GetProcAddress(LoadLibrary('opengl32.dll'), 'glActiveTexture');
    if not Assigned(glDispatchCompute) or not Assigned(glBindImageTexture) then
      raise Exception.Create('OpenGL 4.3 Compute Shader nicht unterstuetzt');
    if not Assigned(glMapBufferRange) or not Assigned(glUnmapBuffer) then
      raise Exception.Create('OpenGL PBO (glMapBufferRange) nicht unterstuetzt');
    if not Assigned(glActiveTexture) then
      raise Exception.Create('glActiveTexture nicht unterstuetzt (OpenGL 1.3 erforderlich)');
    if not Assigned(glUniform1ui) then
      raise Exception.Create('glUniform1ui nicht unterstuetzt (OpenGL 3.0 erforderlich)');
    if not Assigned(glClearBufferData) then
      raise Exception.Create('glClearBufferData nicht unterstuetzt (OpenGL 4.3 erforderlich)');
    if not Assigned(glTexSubImage2D) then
      raise Exception.Create('glTexSubImage2D nicht unterstuetzt');
    FFadeProgram := CompileComputeShader(FADE_SHADER_SRC);
    FComputeProgram := CompileComputeShader(TRANSITION_SHADER_SRC);
    FLocFade_Resolution := glGetUniformLocation(FFadeProgram, 'resolution');
    FLocFade_Decay := glGetUniformLocation(FFadeProgram, 'decay');
    FLoc_Progress := glGetUniformLocation(FComputeProgram, 'progress');
    FLoc_Resolution := glGetUniformLocation(FComputeProgram, 'resolution');
    FLoc_ParticleCount := glGetUniformLocation(FComputeProgram, 'particleCount');
    FLoc_WobbleStrength := glGetUniformLocation(FComputeProgram, 'wobbleStrength');
    // Pre-create the two input textures with empty storage; they are
    // re-allocated (and re-uploaded) on demand when SetImageOld/New drops
    // a pending buffer on the GL thread.
    glGenTextures(1, @FInputTexOld);
    glGenTextures(1, @FInputTexNew);
    FGLInitialized := True;
    Result := True;
  except
    on E: Exception do
    begin
      FErrorMsg := E.Message;
      FGLFailed := True;
      Result := False;
    end
  end;
end;

procedure TGPUParticlePageControl.InitParticles(ACount: Int64);
var
  Zero: Cardinal;
begin
  if ACount <= 0 then
    Exit;
  if FSSBO_Particles = 0 then
    glGenBuffers(1, @FSSBO_Particles);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Particles);
  // 32 bytes per particle: uvec4 pos (16B) + uvec4 extra (16B).
  glBufferData(GL_SHADER_STORAGE_BUFFER, NativeInt(Int64(ACount) * 32), nil, GL_DYNAMIC_COPY);
  Zero := 0;
  glClearBufferData(GL_SHADER_STORAGE_BUFFER, GL_R32UI, GL_RED_INTEGER, GL_UNSIGNED_INT, @Zero);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  FParticleCount := ACount;
end;

procedure TGPUParticlePageControl.CleanupOffscreenGL;
begin
  if FGLContext <> 0 then
  begin
    wglMakeCurrent(FDummyDC, FGLContext);
    if FComputeProgram <> 0 then
      glDeleteProgram(FComputeProgram);
    if FFadeProgram <> 0 then
      glDeleteProgram(FFadeProgram);
    if FSSBO_Particles <> 0 then
      glDeleteBuffers(1, @FSSBO_Particles);
    if (FPBOs[0] <> 0) or (FPBOs[1] <> 0) then
      glDeleteBuffers(2, @FPBOs[0]);
    if FOutputTex <> 0 then
      glDeleteTextures(1, @FOutputTex);
    if FInputTexOld <> 0 then
      glDeleteTextures(1, @FInputTexOld);
    if FInputTexNew <> 0 then
      glDeleteTextures(1, @FInputTexNew);
    wglMakeCurrent(0, 0);
    wglDeleteContext(FGLContext);
    FGLContext := 0;
  end;
  if (FDummyWnd <> 0) and (FDummyDC <> 0) then
    ReleaseDC(FDummyWnd, FDummyDC);
  if FDummyWnd <> 0 then
    DestroyWindow(FDummyWnd);
  FDummyWnd := 0;
  FDummyDC := 0;
  FGLInitialized := False;
end;

procedure TGPUParticlePageControl.EnsureOutputTexture(W, H: Integer);
var
  NewSize: NativeInt;
  I: Integer;
begin
  if (FOutputTex <> 0) and (FTexWidth = W) and (FTexHeight = H) then
    Exit;
  if FOutputTex <> 0 then
    glDeleteTextures(1, @FOutputTex);
  FTexWidth := W;
  FTexHeight := H;
  SetLength(FPixelBuffer, W * H * 4);
  FillChar(Pointer(FPixelBuffer)^, Length(FPixelBuffer), 0);
  glGenTextures(1, @FOutputTex);
  glBindTexture(GL_TEXTURE_2D, FOutputTex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
  glBindTexture(GL_TEXTURE_2D, 0);

  for I := 0 to 1 do
    if FPBOs[I] <> 0 then
      glDeleteBuffers(1, @FPBOs[I]);
  FPBOs[0] := 0;
  FPBOs[1] := 0;
  glGenBuffers(2, @FPBOs[0]);
  NewSize := NativeInt(W) * NativeInt(H) * 4;
  FPBOSize := NewSize;
  for I := 0 to 1 do
  begin
    glBindBuffer(GL_PIXEL_PACK_BUFFER, FPBOs[I]);
    glBufferData(GL_PIXEL_PACK_BUFFER, NewSize, nil, GL_STREAM_READ);
  end;
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  FPBOIndex := 0;
  FPBOHasData := False;
end;

procedure TGPUParticlePageControl.UploadPendingInputs(PrefillOutput: Boolean);
var
  POld: TBytes;
  PNew: TBytes;
  OW, OH, NW, NH: Integer;
  DoPrefill: Boolean;
  CopyBytes: NativeInt;
begin
  FParamLock.Acquire;
  try
    if FInputDirtyOld then
    begin
      POld := FPendingOld;
      OW := FPendingOldW;
      OH := FPendingOldH;
      FInputDirtyOld := False;
    end
    else
    begin
      POld := nil;
      OW := FInputTexOldW;
      OH := FInputTexOldH;
    end;
    if FInputDirtyNew then
    begin
      PNew := FPendingNew;
      NW := FPendingNewW;
      NH := FPendingNewH;
      FInputDirtyNew := False;
    end
    else
    begin
      PNew := nil;
      NW := FInputTexNewW;
      NH := FInputTexNewH;
    end;
  finally
    FParamLock.Release;
  end;

  // On the FIRST dispatch of a new transition we want to PRE-FILL
  // FOutputTex with the OLD page pixels (so the fade-pass does not have to
  // start from black). The caller (DispatchTransition) passes
  // PrefillOutput=True exactly when NeedReseed was true this frame. We can
  // only do the GPU prefill safely when:
  //   (a) PrefillOutput is true.
  //   (b) the OLD input texture was just uploaded, so POld is non-nil.
  //   (c) the OLD texture dimensions exactly match the current
  //       FOutputTex (FTexWidth/FTexHeight). Otherwise glTexSubImage2D
  //       would write out of bounds or leave a partial fill.
  DoPrefill := PrefillOutput and (POld <> nil) and (OW > 0) and (OH > 0)
               and (OW = FTexWidth) and (OH = FTexHeight);

  if (POld <> nil) and (OW > 0) and (OH > 0) and (Length(POld) >= OW * OH * 4) then
  begin
    if (FInputTexOldW <> OW) or (FInputTexOldH <> OH) then
    begin
      if FInputTexOld <> 0 then
        glDeleteTextures(1, @FInputTexOld);
      glGenTextures(1, @FInputTexOld);
      glBindTexture(GL_TEXTURE_2D, FInputTexOld);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, OW, OH);
      FInputTexOldW := OW;
      FInputTexOldH := OH;
    end
    else
      glBindTexture(GL_TEXTURE_2D, FInputTexOld);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, OW, OH, GL_BGRA, GL_UNSIGNED_BYTE, POld[0]);
    glBindTexture(GL_TEXTURE_2D, 0);
  end;

  // Prefill: copy the SAME OLD page pixels into FOutputTex so the fade-pass
  // does not start from black on the first dispatch of a new transition.
  // We use the SAME source bytes (POld) that were just uploaded to
  // FInputTexOld - no second copy, no new uniform. The dimension check
  // (OW = FTexWidth, OH = FTexHeight) was computed above as DoPrefill.
  //
  // CRITICAL ADDITIONAL STEP: also copy POld into FPixelBuffer on the CPU
  // side. FPixelBuffer is what RenderEffect blits to the screen when
  // FPreviewFramesLeft reaches 0 (i.e. from frame 2 onwards). After
  // EnsureOutputTexture it is filled with zeros (black) - and the async
  // PBO readback in DispatchTransition may not have delivered the real
  // first computed frame yet when RenderEffect reads FPixelBuffer (the
  // PBO DMA is asynchronous and glMapBufferRange(GL_MAP_READ_BIT) is
  // implementation-defined on whether it blocks). Without this CPU-side
  // prefill, frame 2 could briefly show black before the real particle
  // frame arrives - exactly the "effekt geht kurz los, dann zurück, dann
  // richtig" flicker the user reported. By pre-seeding FPixelBuffer with
  // the old page here (synchronously, on the GL thread, before any async
  // DMA is in flight), frame 2 falls back to the old page if the DMA has
  // not finished yet - which is visually identical to frame 1's
  // FStartPreview, so the transition from preview to compute is seamless.
  if DoPrefill and (FOutputTex <> 0) then
  begin
    // GPU side: FOutputTex = old page (so fade-pass starts from it, not black).
    glBindTexture(GL_TEXTURE_2D, FOutputTex);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, OW, OH, GL_BGRA, GL_UNSIGNED_BYTE, POld[0]);
    glBindTexture(GL_TEXTURE_2D, 0);
    // CPU side: FPixelBuffer = old page (synchronous fallback for the
    // first few frames until the PBO readback delivers real frames).
    // FPixelBuffer was sized by EnsureOutputTexture to W*H*4 = OW*OH*4.
    CopyBytes := NativeInt(OW) * NativeInt(OH) * 4;
    if (FPixelBuffer <> nil) and (NativeInt(Length(FPixelBuffer)) >= CopyBytes)
       and (NativeInt(Length(POld)) >= CopyBytes) then
      System.Move(POld[0], Pointer(FPixelBuffer)^, CopyBytes);
  end;

  if (PNew <> nil) and (NW > 0) and (NH > 0) and (Length(PNew) >= NW * NH * 4) then
  begin
    if (FInputTexNewW <> NW) or (FInputTexNewH <> NH) then
    begin
      if FInputTexNew <> 0 then
        glDeleteTextures(1, @FInputTexNew);
      glGenTextures(1, @FInputTexNew);
      glBindTexture(GL_TEXTURE_2D, FInputTexNew);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, NW, NH);
      FInputTexNewW := NW;
      FInputTexNewH := NH;
    end
    else
      glBindTexture(GL_TEXTURE_2D, FInputTexNew);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, NW, NH, GL_BGRA, GL_UNSIGNED_BYTE, PNew[0]);
    glBindTexture(GL_TEXTURE_2D, 0);
  end;
end;

procedure TGPUParticlePageControl.DispatchTransition(
  const ATime, ADeltaTime: Double; ViewW, ViewH, SimW, SimH: Integer);
var
  GroupsX, GroupsY: Cardinal;
  TotalGroups: Int64;
  ReadPBO, WritePBO: Cardinal;
  Mapped: Pointer;
  P: Single;
  NeedReseed: Boolean;
  NeedPrefill: Boolean;
  Zero: Cardinal;
begin
  wglMakeCurrent(FDummyDC, FGLContext);
  EnsureOutputTexture(SimW, SimH);
  // One particle per output pixel - matches the seeding math in the shader
  // (idx % resolution.x, idx / resolution.x).
  if FParticleCount <> Int64(SimW) * Int64(SimH) then
    InitParticles(Int64(SimW) * Int64(SimH));

  // Pick up a pending re-seed request from StartTransition. We zero the
  // SSBO via glClearBufferData on the GL thread (where a context is
  // current) - this resets every particle's seeded flag so the shader's
  // lazy-init branch re-runs against the currently bound input textures.
  // We consume FNeedOutputPrefill in the SAME atomic lock acquisition as
  // FNeedReseed: both are set together by StartTransition, and both must
  // be acted on together by the same DispatchTransition invocation. If we
  // read them separately (one in DispatchTransition, one in
  // UploadPendingInputs), a second StartTransition that arrives between
  // the two reads could set the flags again and we would act on a
  // mismatched pair - e.g. reseed the SSBO but prefill the output texture
  // from the OLD pair of input textures, leaving the shader uninitialized
  // against the new pair.
  FParamLock.Acquire;
  try
    NeedReseed := FNeedReseed;
    FNeedReseed := False;
    NeedPrefill := FNeedOutputPrefill;
    FNeedOutputPrefill := False;
  finally
    FParamLock.Release;
  end;
  if NeedReseed and (FSSBO_Particles <> 0) then
  begin
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Particles);
    Zero := 0;
    glClearBufferData(GL_SHADER_STORAGE_BUFFER, GL_R32UI, GL_RED_INTEGER, GL_UNSIGNED_INT, @Zero);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  end;

  UploadPendingInputs(NeedPrefill);

  // Async readback of the PREVIOUS frame's PBO - same trick as the Liquid.
  if FPBOHasData then
  begin
    ReadPBO := FPBOs[FPBOIndex xor 1];
    glBindBuffer(GL_PIXEL_PACK_BUFFER, ReadPBO);
    Mapped := glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, FPBOSize, GL_MAP_READ_BIT);
    if Mapped <> nil then
    begin
      System.Move(Mapped^, Pointer(FPixelBuffer)^, FPBOSize);
      glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    end;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  end;

  // Fade pass (background trail decay) - same as the Liquid. Without this,
  // every particle leaves a permanent smear; with it, the screen fades
  // gently between dispatches, which softens the particle cloud.
  glUseProgram(FFadeProgram);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  glUniform2f(FLocFade_Resolution, SimW, SimH);
  glUniform1f(FLocFade_Decay, FTrailDecay);
  GroupsX := (Cardinal(SimW) + 15) div 16;
  GroupsY := (Cardinal(SimH) + 15) div 16;
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);

  // Transition pass.
  glUseProgram(FComputeProgram);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FSSBO_Particles);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);

  // Bind the two input textures to sampler units 1 and 2 (matches the
  // layout(binding = N) declarations in the shader).
  glActiveTexture(Cardinal(GL_TEXTURE0 + 1));
  glBindTexture(GL_TEXTURE_2D, FInputTexOld);
  glActiveTexture(Cardinal(GL_TEXTURE0 + 2));
  glBindTexture(GL_TEXTURE_2D, FInputTexNew);

  FParamLock.Acquire;
  try
    P := FProgress;
  finally
    FParamLock.Release;
  end;
  glUniform1f(FLoc_Progress, P);
  glUniform2f(FLoc_Resolution, SimW, SimH);
  glUniform1f(FLoc_WobbleStrength, FWobbleStrength);
  glUniform1ui(FLoc_ParticleCount, Cardinal(FParticleCount));

  TotalGroups := (FParticleCount + 255) div 256;
  if TotalGroups > 32768 then
    GroupsX := 32768
  else
    GroupsX := Cardinal(TotalGroups);
  GroupsY := Cardinal((TotalGroups + Int64(GroupsX) - 1) div GroupsX);
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT or GL_TEXTURE_FETCH_BARRIER_BIT);

  // Async readback into WRITE PBO.
  WritePBO := FPBOs[FPBOIndex];
  glBindBuffer(GL_PIXEL_PACK_BUFFER, WritePBO);
  glBindTexture(GL_TEXTURE_2D, FOutputTex);
  glGetTexImage(GL_TEXTURE_2D, 0, GL_BGRA, GL_UNSIGNED_BYTE, nil);
  glBindTexture(GL_TEXTURE_2D, 0);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

  FPBOIndex := FPBOIndex xor 1;
  FPBOHasData := True;

  // Reset the active texture unit back to GL_TEXTURE0. We bound input
  // textures on units 1 and 2 above; without this reset, the GL state
  // stays on unit 2 and the next EnsureOutputTexture / UploadPendingInputs
  // glBindTexture call would silently bind onto unit 2 instead of unit 0,
  // which can cause the "next page bleeds through behind the animation"
  // artifact because the wrong texture gets uploaded.
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, 0);
  glUseProgram(0);
end;

procedure TGPUParticlePageControl.UpdateLogic(const DeltaTime: Double);
begin
  if FTransitioning then
  begin
    FParamLock.Acquire;
    try
      // Accumulate progress from the per-frame DeltaTime. We deliberately
      // do NOT use an absolute thread-side timestamp here: UpdateLogic only
      // receives DeltaTime, and a drift in the absolute clock would make
      // the transition speed depend on when the thread started. DeltaTime
      // integration keeps the visual duration stable at FDuration seconds.
      FProgress := FProgress + Single(DeltaTime) / Max(FDuration, 0.001);
      if FProgress >= 1.0 then
      begin
        FProgress := 1.0;
        FTransitioning := False;
        // Arm the transition-complete notification. RenderEffect will pick
        // this up and marshal the call to the main thread via TThread.Queue.
        // We do not call the handler directly here: UpdateLogic runs on the
        // GL thread, and the host's handler will touch VCL/FMX controls
        // which must only be touched from the UI thread.
        FCompletePending := True;
        // The SSBO seeded-flags are left intact here; the next call to
        // StartTransition will set FNeedReseed := True so DispatchTransition
        // zeroes the SSBO before the next transition begins.
      end;
    finally
      FParamLock.Release;
    end;
  end;
end;

procedure TGPUParticlePageControl.RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double);
var
  ViewW, ViewH, SimW, SimH: Integer;
  ImgInfo: TSkImageInfo;
  GPUImg: ISkImage;
  LFireComplete: Boolean;
begin
  ViewW := Round(ADest.Width);
  ViewH := Round(ADest.Height);
  if (ViewW <= 0) or (ViewH <= 0) then
    Exit;
  if not Active then
  begin
    inherited RenderEffect(ACanvas, ADest, ATime);
    Exit;
  end;
  if not InitOffscreenGL then
  begin
    ACanvas.Clear($FF1A0000);
    Exit;
  end;

  // Pick up the transition-complete flag under the param lock so a fast
  // second StartTransition cannot race with the read here. Done before the
  // early-out below so the event still fires once even if FTransitioning
  // has already been flipped to False by UpdateLogic.
  FParamLock.Acquire;
  try
    LFireComplete := FCompletePending;
    FCompletePending := False;
  finally
    FParamLock.Release;
  end;

  // IMPORTANT power-saving early-out: when no transition is running AND no
  // completion is pending, do NOT dispatch compute shaders. Without this
  // the GL thread kept calling glDispatchCompute every frame forever, which
  // was the 5% GPU / 12% CPU load you saw after the effect ended. We still
  // draw the last cached pixel buffer so the overlay does not flash black
  // for one frame before the host hides it.
  if (not FTransitioning) and (not LFireComplete) then
  begin
    ACanvas.Clear(TAlphaColors.Black);
    if (FPixelBuffer <> nil) and (FPBOSize > 0) then
    begin
      SimW := Round(FLastSimW);
      SimH := Round(FLastSimH);
      if (SimW > 0) and (SimH > 0) then
      begin
        ImgInfo := TSkImageInfo.Create(SimW, SimH, TSkColorType.BGRA8888, TSkAlphaType.Premul);
        GPUImg := TSkImage.MakeFromRaster(ImgInfo, Pointer(FPixelBuffer), SimW * 4);
        if Assigned(GPUImg) then
          ACanvas.DrawImageRect(GPUImg, RectF(0, 0, SimW, SimH), RectF(0, 0, ViewW, ViewH), TSkSamplingOptions.Medium);
      end;
    end;
    Exit;
  end;

  if (ViewW > 1100) or (ViewH > 750) then
  begin
    SimW := ViewW div 2;
    SimH := ViewH div 2;
  end
  else
  begin
    SimW := ViewW;
    SimH := ViewH;
  end;
  // Remember the sim size so the early-out branch above can blit the last
  // frame at the right resolution.
  FLastSimW := SimW;
  FLastSimH := SimH;

  DispatchTransition(ATime, 1.0 / 60.0, ViewW, ViewH, SimW, SimH);
  if FGPULastTime <= 0 then
    FGPULastTime := ATime;
  Inc(FGPUFrameCount);
  if (ATime - FGPULastTime) >= 1.0 then
  begin
    FGPURealFPS := Round(FGPUFrameCount / (ATime - FGPULastTime));
    FGPUFrameCount := 0;
    FGPULastTime := ATime;
  end;
  ACanvas.Clear(TAlphaColors.Black);
  // Show FStartPreview for the first TWO frames of a new transition. This
  // works together with the CPU-side prefill in UploadPendingInputs to
  // give a fully race-free startup sequence:
  //
  //   Frame 1: FPreviewFramesLeft 2 -> 1, blit FStartPreview. DispatchTransition
  //     has already prefilled FPixelBuffer = POld synchronously (CPU
  //     System.Move), so FPixelBuffer is guaranteed to be a valid image of
  //     the old page from this frame onwards.
  //   Frame 2: FPreviewFramesLeft 1 -> 0, blit FStartPreview. DispatchTransition
  //     has read back PBO[0] (DMA from frame 1); even if that DMA has not
  //     completed yet, FPixelBuffer still holds the prefilled POld (the readback
  //     may overwrite it with stale data, but visually it is still the old
  //     page - or near it). We do not show it this frame anyway.
  //   Frame 3: FPreviewFramesLeft 0, blit FPixelBuffer. By now the DMA from
  //     frame 2 into PBO[1] has completed (two full frames of latency), so
  //     glMapBufferRange returns the real first computed frame.
  //
  // The CPU prefill is the safety net that makes the hand-off seamless even
  // if the driver does not block on glMapBufferRange as the spec says it
  // should. Without it, frame 3 could briefly show black - exactly the
  // "effekt geht kurz los, dann zurück, dann richtig los" artifact the user
  // reported.
  if FPreviewFramesLeft > 0 then
  begin
    Dec(FPreviewFramesLeft);
    if Assigned(FStartPreview) then
      ACanvas.DrawImageRect(FStartPreview,
        RectF(0, 0, FStartPreview.Width, FStartPreview.Height),
        RectF(0, 0, ViewW, ViewH), TSkSamplingOptions.Medium);
    // If FStartPreview is nil (e.g. SetImageOld was never called with valid
    // data), we fall through and leave the canvas cleared to black - still
    // bounded to at most two frames.
  end
  else
  begin
    ImgInfo := TSkImageInfo.Create(SimW, SimH, TSkColorType.BGRA8888, TSkAlphaType.Premul);
    GPUImg := TSkImage.MakeFromRaster(ImgInfo, Pointer(FPixelBuffer), SimW * 4);
    if Assigned(GPUImg) then
      ACanvas.DrawImageRect(GPUImg, RectF(0, 0, SimW, SimH), RectF(0, 0, ViewW, ViewH), TSkSamplingOptions.Medium);
  end;

  // Marshal the transition-complete notification from the GL thread to the
  // UI thread. We capture only the Self pointer (safe: the component owns the
  // thread; if the component is destroyed, StopThread joins the thread first,
  // so no queued callback can run against a freed instance). The handler is
  // expected to hide the overlay and show the new page panel.
  if LFireComplete then
  begin
    TThread.Queue(nil,
      procedure
      begin
        if not (csDestroying in ComponentState) and Assigned(FOnTransitionComplete) then
          FOnTransitionComplete(Self);
      end);
  end;
end;

end.
