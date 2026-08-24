# SkiaPageControl
Delphi RAD Studio skia4delphi - SkiaPageControl (Prototype)   
       
A next-generation VCL PageControl prototype that brings GPU-accelerated, fluid transitions to Delphi applications using the Skia graphics library.    

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/SkiaPageControl)
   
    
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

      
🎨 Skia4Delphi Components:    
   Alive Progress/Loading circle https://github.com/LaMitaOne/SkiaAliveProgress   
   Audio Visualizer https://github.com/LaMitaOne/SkiaAVisualizer        
   CustomThreadedBase (this i use mostly) https://github.com/LaMitaOne/SkiaCustomThreadedBase    
   Skia Alive Grid https://github.com/LaMitaOne/Skia-AliveGrid    
   Skia-Flowmotion animated image grid https://github.com/LaMitaOne/skia-flowmotion   
   Skia-Slideshow https://github.com/LaMitaOne/Skia-Slideshow   
   Skia-Circlepopup https://github.com/LaMitaOne/skia-circlepopup  
   Skia-CubesPopup https://github.com/LaMitaOne/SkiaCubesPopup   
   Skia-Button https://github.com/LaMitaOne/SkiaButton    
   Skia Desktop Pet https://github.com/LaMitaOne/SkiaDesktopPetBase    
         
🧪 Skia4Delphi experimental Components:    
   CustomMultithreadedBase  https://github.com/LaMitaOne/SkiaCustomMultiThreadedBase    
   Surface Widget/modules rendering engine https://github.com/LaMitaOne/MRX-Skia-Surface   
   LCARS fluid engine https://github.com/LaMitaOne/Skia-LCARS-Fluid-Engine   
   Fluid Magma effect https://github.com/LaMitaOne/Fluid-Magma-Effect    
      
