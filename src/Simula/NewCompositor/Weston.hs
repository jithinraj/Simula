module Simula.NewCompositor.Weston where

import Control.Concurrent
import Control.Lens
import Control.Monad
import qualified Data.Map as M
import Data.IORef
import Data.Word
import Data.Typeable
import Foreign
import Foreign.C
import Graphics.Rendering.OpenGL hiding (scale, translate, rotate, Rect)
import Linear
import Linear.OpenGL
import System.Clock
import System.Environment

import Simula.WaylandServer
import Simula.Weston
import Simula.WestonDesktop


import Simula.NewCompositor.Compositor
import Simula.NewCompositor.Geometry
import Simula.NewCompositor.OpenGL
import Simula.NewCompositor.SceneGraph
import Simula.NewCompositor.Wayland.Input
import Simula.NewCompositor.Wayland.Output
import Simula.NewCompositor.WindowManager
import Simula.NewCompositor.Utils
import Simula.NewCompositor.Types

data SimulaSurface = SimulaSurface {
  _simulaSurfaceBase :: BaseWaylandSurface,
  _simulaSurfaceWestonDesktopSurface :: WestonDesktopSurface,
  _simulaSurfaceCompositor :: SimulaCompositor,
  _simulaSurfaceTexture :: IORef (Maybe TextureObject)
  } deriving (Eq, Typeable)

data SimulaCompositor = SimulaCompositor {
  _simulaCompositorScene :: Scene,
  _simulaCompositorDisplay :: Display,
  _simulaCompositorWlDisplay :: WlDisplay,
  _simulaCompositorWestonCompositor :: WestonCompositor,
  _simulaCompositorSurfaceMap :: IORef (M.Map WestonDesktopSurface SimulaSurface),
  _simulaCompositorOpenGlData :: OpenGLData,
  _simulaCompositorOutput :: IORef (Maybe WestonOutput),
  _simulaCompositorGlContext :: IORef (Maybe SimulaOpenGLContext)
  } deriving Eq

data SimulaSeat = SimulaSeat

data OpenGLData = OpenGLData {
  _openGlDataPpcm :: Float,
  _openGlDataTextureBlitter :: TextureBlitter,
  _openGlDataSurfaceFbo :: FramebufferObject
  } deriving Eq

data SimulaOpenGLContext = SimulaOpenGLContext {
  _simulaOpenGlContextEglContext :: EGLContext,
  _simulaOpenGlContextEglDisplay :: EGLDisplay,
  _simulaOpenGlContextEglSurface :: EGLSurface
  } deriving (Eq, Typeable)

data TextureBlitter = TextureBlitter {
  _textureBlitterProgram :: Program,
  _textureBlitterVertexCoordEntry :: AttribLocation,
  _textureBlitterTextureCoordEntry :: AttribLocation,
  _textureBlitterMatrixLocation :: UniformLocation
  } deriving Eq

makeLenses ''SimulaSurface
makeLenses ''SimulaCompositor
makeLenses ''OpenGLData
makeLenses ''SimulaOpenGLContext
makeLenses ''TextureBlitter

instance OpenGLContext SimulaOpenGLContext where
  glCtxMakeCurrent this = do
    eglMakeCurrent egldp eglsurf eglsurf eglctx

    where
      eglctx = this ^. simulaOpenGlContextEglContext
      egldp = this ^. simulaOpenGlContextEglDisplay
      eglsurf = this ^. simulaOpenGlContextEglSurface



instance HasBaseWaylandSurface SimulaSurface where
  baseWaylandSurface = simulaSurfaceBase

newSimulaSurface :: WestonDesktopSurface -> SimulaCompositor -> WaylandSurfaceType -> IO SimulaSurface
newSimulaSurface ws comp ty = SimulaSurface
                              <$> newBaseWaylandSurface ty
                              <*> pure ws <*> pure comp
                              <*> newIORef Nothing

newOpenGlData :: IO OpenGLData
newOpenGlData = OpenGLData 64 <$> newTextureBlitter <*> genObjectName

newTextureBlitter :: IO TextureBlitter
newTextureBlitter = do
  program <- getProgram ShaderTextureBlitter
  blend $= Enabled
  blendFunc $= (One, OneMinusSrcAlpha)
  TextureBlitter
    <$> pure program
    <*> get (attribLocation program "vertexCoordEntry")
    <*> get (attribLocation program "textureCoordEntry")
    <*> get (uniformLocation program "matrix")

bindTextureBlitter :: TextureBlitter -> IO ()
bindTextureBlitter tb = currentProgram $= Just (tb ^. textureBlitterProgram)

blitterDrawTexture :: TextureBlitter -> TextureObject -> Rect Float -> V2 Int -> Int -> Bool -> Bool -> IO ()
blitterDrawTexture tb tex targetRect targetSize depth targetInvertedY sourceInvertedY = do
  viewport $= (Position 0 0, Size (fromIntegral $ targetSize ^. _x) (fromIntegral $ targetSize ^. _y))

  let vertexCoordEntry = tb ^. textureBlitterVertexCoordEntry
  let textureCoordEntry = tb ^. textureBlitterTextureCoordEntry
  let matrix = tb ^. textureBlitterMatrixLocation

  vertexAttribArray vertexCoordEntry $= Enabled
  vertexAttribArray textureCoordEntry $= Enabled

  withArrayLen vertexCoordinates $ \len arrPtr ->
    vertexAttribPointer vertexCoordEntry $= (ToFloat, VertexArrayDescriptor 3 Float 0 arrPtr)
  withArrayLen textureCoordinates $ \len arrPtr ->
    vertexAttribPointer textureCoordEntry $= (ToFloat, VertexArrayDescriptor 2 Float 0 arrPtr)

  uniform matrix $= transform ^. m44GLmatrix

  textureBinding Texture2D $= Just tex
  textureFilter Texture2D $= ((Nearest, Nothing), Nearest)
  drawArrays TriangleFan 0 4

  textureBinding Texture2D $= Nothing

  vertexAttribArray vertexCoordEntry $= Disabled
  vertexAttribArray textureCoordEntry $= Disabled
  checkForErrors

  where
    z = fromIntegral depth / 1000
    
    textureCoordinates = [ 0, 0
                         , 1, 0
                         , 1, 1
                         , 0, 1 ] :: [Float]
    vertexCoordinates =  [ x1, y1, z
                         , x2, y1, z
                         , x2, y2, z
                         , x1, y2, z ] :: [Float]
    
    x1 = rectLeft targetRect
    x2 = rectRight targetRect
    invertTarget y | targetInvertedY = y
                   | otherwise = (fromIntegral $ targetSize ^. _y) - y

    invertSource y1 y2 | sourceInvertedY = (y1, y2)
                       | otherwise = (y2, y1)
  
    (y1', y2') = invertSource (rectTop targetRect) (rectBottom targetRect)
    y1 = invertTarget y1'
    y2 = invertTarget y2'

    width = fromIntegral $ targetSize ^. _x :: Float
    height = fromIntegral $ targetSize ^. _y :: Float
    
    scaleMat = scale $ V3 (2 / width) (2 / height) 1
    translateMat = translate $ V3 (negate width / 2) (negate height / 2) 0
    transform = translateMat !*! scaleMat :: M44 Float
  

setTimeout :: IO () -> Int -> IO ThreadId
setTimeout ioOperation ms =
  forkIO $ do
    threadDelay (ms*1000)
    ioOperation

--BIG TODO: type safety for C bindings, e.g. WlSignal should encode the type of the NotifyFunc data.

instance Compositor SimulaCompositor where
  compositorDisplay = return . view simulaCompositorDisplay
  compositorWlDisplay = view simulaCompositorWlDisplay
  compositorOpenGLContext this = do
    Just glctx <- readIORef (this ^. simulaCompositorGlContext)
    return (Some glctx)
    
  compositorGetSurfaceFromResource comp resource = do
    ptr <- wlResourceData resource
    let surface = WestonDesktopSurface (castPtr ptr)
    Some <$> newSimulaSurface surface comp NA
    

--BUG TODO: need an actual wl_shell
newSimulaCompositor :: Scene -> Display -> IO SimulaCompositor
newSimulaCompositor scene display = do
  wldp <- wl_display_create
  wcomp <- weston_compositor_create wldp nullPtr

  setup_weston_log_handler
  westonCompositorSetEmptyRuleNames wcomp

  --todo hack; make this into a proper withXXX function
  res <- with (WestonX11BackendConfig (WestonBackendConfig westonX11BackendConfigVersion (sizeOf (undefined :: WestonX11BackendConfig)))
           False
           False
           False) $ weston_compositor_load_backend wcomp WestonBackendX11 . castPtr

  when (res > 0) $ ioError $ userError "Error when loading backend"
  
  socketName <- wl_display_add_socket_auto wldp
  putStrLn $ "Socket: " ++ socketName
  setEnv "WAYLAND_DISPLAY" socketName

  compositor <- SimulaCompositor scene display wldp wcomp
                <$> newIORef M.empty <*> newOpenGlData
                <*> newIORef Nothing <*> newIORef Nothing

  windowedApi <- weston_windowed_output_get_api wcomp

  let outputPendingSignal = westonCompositorOutputPendingSignal wcomp
  outputPendingPtr <- createNotifyFuncPtr (onOutputPending windowedApi compositor)
  addListenerToSignal outputPendingSignal outputPendingPtr

  let outputCreatedSignal = westonCompositorOutputCreatedSignal wcomp
  outputCreatedPtr <- createNotifyFuncPtr (onOutputCreated compositor)
  addListenerToSignal outputCreatedSignal outputCreatedPtr
 
  westonWindowedOutputCreate windowedApi wcomp "X"


  let api = defaultWestonDesktopApi {
        apiSurfaceAdded = onSurfaceCreated compositor,
        apiSurfaceRemoved = onSurfaceDestroyed compositor
        }

  mainLayer <- newWestonLayer wcomp
  weston_layer_set_position mainLayer WestonLayerPositionNormal
  bgLayer <- newWestonLayer wcomp
  weston_layer_set_position mainLayer WestonLayerPositionBackground

  bgSurface <- weston_surface_create wcomp
  bgView <- weston_view_create bgSurface

  weston_surface_set_color bgSurface 0.16 0.32 0.48 1
  pixman_region32_fini (westonSurfaceOpaque bgSurface)
  pixman_region32_init_rect (westonSurfaceOpaque bgSurface) 0 0 2000 2000

  pixman_region32_fini (westonSurfaceInput bgSurface)
  pixman_region32_init_rect (westonSurfaceInput bgSurface) 0 0 2000 2000

  weston_surface_set_size bgSurface 2000 2000
  weston_view_set_position bgView 0 0
  weston_layer_entry_insert (westonLayerViewList bgLayer) (westonViewLayerEntry bgView)
  weston_view_update_transform bgView
  
  
  
  westonDesktopCreate wcomp api nullPtr

  return compositor

 where
   onSurfaceCreated compositor surface  _ = do
     putStrLn "surface created"
     view <- weston_desktop_surface_create_view surface
     simulaSurface <- newSimulaSurface surface compositor NA
     modifyIORef' (compositor ^. simulaCompositorSurfaceMap) (M.insert surface simulaSurface)

     let wm = compositor ^. simulaCompositorScene.sceneWindowManager
     -- need to figure out surface type
     wmMapSurface wm simulaSurface TopLevel
     return ()

   onSurfaceDestroyed compositor surface _ = do
     --TODO destroy surface in wm
     modifyIORef' (compositor ^. simulaCompositorSurfaceMap) (M.delete surface)

   onSurfaceCommit = undefined

   onOutputPending windowedApi compositor _ outputPtr = do
     putStrLn "output pending"
     let output = WestonOutput $ castPtr outputPtr
     --TODO hack
     weston_output_set_scale output 1
     weston_output_set_transform output 0
     westonWindowedOutputSetSize windowedApi output 2000 2000

     weston_output_enable output
     return ()


   onOutputCreated compositor _ outputPtr = do
     let output = WestonOutput $ castPtr outputPtr
     writeIORef (compositor ^. simulaCompositorOutput) $ Just output
     let wc = compositor ^. simulaCompositorWestonCompositor
     renderer <- westonCompositorGlRenderer wc
     eglctx <- westonGlRendererContext renderer
     egldp <- westonGlRendererDisplay renderer
     eglsurf <- westonOutputRendererSurface output
     let glctx = SimulaOpenGLContext eglctx egldp eglsurf

     let (EGLDisplay egldpPtr) = egldp
     putStrLn $ show egldpPtr
     
     writeIORef (compositor ^. simulaCompositorGlContext) (Just glctx)
     

instance WaylandSurface SimulaSurface where
  wsTexture = views simulaSurfaceTexture readIORef
  
  wsSize surf = V2 <$> weston_desktop_surface_get_width ws <*> weston_desktop_surface_get_height ws
    where
      ws = surf ^. simulaSurfaceWestonDesktopSurface
  
  setWsSize surf (V2 x y) =  weston_desktop_surface_set_size ws x y
    where
      ws = surf ^. simulaSurfaceWestonDesktopSurface
  
  wsPosition surf = (fmap.fmap) fromIntegral $ 
    V2 <$> weston_desktop_surface_get_position_x ws <*> weston_desktop_surface_get_position_y ws

    where
      ws = surf ^. simulaSurfaceWestonDesktopSurface
    
  wsPrepare surf = do
    texture <- composeSurface surf (surf ^. simulaSurfaceCompositor.simulaCompositorOpenGlData)
    oldTex <- wsTexture surf 
    case oldTex of
      Nothing -> return ()
      Just oldTex -> do
        deleteObjectName oldTex
    writeIORef (surf ^. simulaSurfaceTexture) (Just texture)
  
  wsSendEvent surf event = undefined


textureFromSurface :: WestonSurface -> IO TextureObject
textureFromSurface ws = do
  texture <- genObjectName
  textureBinding Texture2D $= Just texture

  buffer <- wl_shm_buffer_get . westonBufferResource $ westonSurfaceBuffer ws

  format <- wl_shm_buffer_get_format buffer
  width <- fromIntegral <$> wl_shm_buffer_get_width buffer
  height <- fromIntegral <$> wl_shm_buffer_get_height buffer

  --TODO support more formats
  when (format `notElem` [WlShmFormatArgb8888, WlShmFormatXrgb8888]) . ioError . userError $ "Unsupported pixel format " ++ show format
  
  withShmBuffer buffer $ \ptr -> do
    texImage2D Texture2D NoProxy 0 RGBA' (TextureSize2D width height) 0 (PixelData BGRA UnsignedInt8888Rev ptr)

  textureBinding Texture2D $= Nothing
  checkForErrors
  return texture


composeSurface :: SimulaSurface -> OpenGLData -> IO TextureObject
composeSurface surf gld = do
  putStrLn "composed surface"
  ws <- weston_desktop_surface_get_surface $ surf ^. simulaSurfaceWestonDesktopSurface
  size <- wsSize surf

  let fbo = gld ^. openGlDataSurfaceFbo
  bindFramebuffer Framebuffer $= fbo

  texture <- textureFromSurface ws

  framebufferTexture2D Framebuffer (ColorAttachment 0) Texture2D texture 0
  paintChildren ws ws size gld

  --TODO what does this do?
  framebufferTexture2D Framebuffer (ColorAttachment 0) Texture2D (TextureObject 0) 0
  bindFramebuffer Framebuffer $= defaultFramebufferObject
  checkForErrors
  return texture
  

paintChildren :: WestonSurface -> WestonSurface -> V2 Int -> OpenGLData -> IO ()
paintChildren surface window windowSize gld = do
  subsurfaces <- westonSurfaceSubsurfaces surface

  when (not $ null subsurfaces) $ forM_ subsurfaces $ \ss -> do
    let subsurface = westonSubsurfaceSurface ss

    (sView:_) <- westonSurfaceViews surface
    (ssView:_) <- westonSurfaceViews subsurface

    sPos <- westonViewPos sView
    ssPos <- westonViewPos ssView
    let p = sPos ^+^ ssPos

    windowSize <- westonSurfaceSize window
    subSize <- westonSurfaceSize subsurface

    -- .isValid() checks for all (>)
    when (all (>0) subSize) $ do
      tex <- textureFromSurface subsurface
      let geo = Rect p (fromIntegral <$> subSize)
      windowInverted <- westonSurfaceIsYInverted window
      subsurfaceInverted <- westonSurfaceIsYInverted subsurface
      blitterDrawTexture (gld ^. openGlDataTextureBlitter) tex geo windowSize 0 windowInverted subsurfaceInverted
      deleteObjectName tex
    paintChildren subsurface window windowSize gld
    

compositorRender :: SimulaCompositor -> IO ()
compositorRender comp = do
  surfaceMap <- readIORef (comp ^. simulaCompositorSurfaceMap)
  Just glctx <- readIORef (comp ^. simulaCompositorGlContext)
  Just output <- readIORef (comp ^. simulaCompositorOutput)


  glCtxMakeCurrent glctx
  -- set up context
  
  let surfaces = M.keys surfaceMap
  let scene = comp ^. simulaCompositorScene

  time <- getTime Realtime
  
  scenePrepareForFrame scene time
  checkForErrors
  -- weston_surface_schedule_repaint?
  
  moveCamera
  sceneDrawFrame scene
  checkForErrors
  sceneFinishFrame scene
  checkForErrors


  emitOutputFrameSignal output
  eglSwapBuffers (glctx ^. simulaOpenGlContextEglDisplay) (glctx ^. simulaOpenGlContextEglSurface)

  putStrLn "Rendered"

  where
    moveCamera = return ()
{-
    if(m_camIsMoving) {
        glm::vec4 camPos;
        camPos *= 0;
        camPos.w = 1;
        glm::vec4 delta = camPos;
        delta.x = m_camMoveVec.x;
        delta.y = m_camMoveVec.y;
        delta.z = m_camMoveVec.z;

        const float speed = 0.01;
        delta *= speed;
        delta.w /= speed;
        glm::mat4 trans = display()->transform();
        //camPos = trans * camPos;
        //delta = trans * delta;
        glm::vec3 move = glm::vec3(delta.x/delta.w - camPos.x/camPos.w, delta.y/delta.w - camPos.y/camPos.w,
                                   delta.z/delta.w - camPos.z/camPos.w);
        trans = glm::translate(trans, move);
        display()->setTransform(trans);
    }
-}
