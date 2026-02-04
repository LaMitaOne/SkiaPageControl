# SkiaPageControl
Delphi RAD Studio skia4delphi - SkiaPageControl (Prototype)   
       
A next-generation VCL PageControl prototype that brings GPU-accelerated, fluid transitions to Delphi applications using the Skia graphics library.    
    
This project is a proof-of-concept to demonstrate that legacy VCL controls can be modernized with smooth, high-performance animations without heavy CPU overhead.   
   
✨ Features    
    
    Smooth Animations: Hardware-accelerated transitions using Skia.    
    Blur Effect: A unique "Page Blur" transition that blurs the old page out to reveal the new one.    
    Variety of Effects: Includes Fade, Slide, and Page Blur.    
    High Performance: Minimal CPU and GPU usage. Animations run smoothly.    
    
🚧 Current Status: Prototype    
    
Please note that this is currently a prototype and not a final production-ready component.   
    
    Architecture: It uses a snapshot technique (capturing VCL panels to bitmaps) to render the animation frames.   
    Limitations: Complex controls (like TWebBrowser or DirectX components) may not render correctly in the snapshot.   
    Scope: The current implementation focuses on the core animation engine. Design-time support, proper streaming, and property editors are not yet implemented.    
   
🚀 How it works   
    
    When a page switch occurs, the component snapshots the Old Page and the New Page into memory bitmaps.   
    It hides the actual VCL controls to prevent "ghosting" or artifacts.   
    A Skia overlay (TSkPaintBox) is brought to the front to render the transition animation (Blur/Slide) using the cached bitmaps.   
    Once the animation finishes, the overlay is hidden, and the new VCL controls are revealed.   
     
Sample project and exe included    
 
🔧 Dependencies    
   
     Delphi (VCL)   
     Skia4Delphi  (for Skia bindings)   
        

---- we must put it in a panel then it hides other ctrls ... ;)  oh and we could animate any ctrl... that way
