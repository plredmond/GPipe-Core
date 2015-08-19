{-# LANGUAGE RankNTypes, GeneralizedNewtypeDeriving, FlexibleContexts, FlexibleInstances, GADTs, DeriveDataTypeable #-}

module Graphics.GPipe.Internal.Context 
(
    ContextFactory,
    ContextHandle(..),
    ContextT(),
    GPipeException(..),
    runContextT,
    runSharedContextT,
    liftContextIO,
    liftContextIOAsync,
    addContextFinalizer,
    getContextFinalizerAdder,
    getRenderContextFinalizerAdder ,
    swapContextBuffers,
    addVAOBufferFinalizer,
    addFBOTextureFinalizer,
    getContextData,
    getRenderContextData,
    getVAO, setVAO,
    getFBO, setFBO,
    VAOKey(..), FBOKey(..), FBOKeys(..),
    Render(..), render, getContextBuffersSize
)
where

import Graphics.GPipe.Internal.Format
import Control.Monad.Exception (MonadException, Exception, MonadAsyncException,bracket)
import Control.Monad.Trans.Reader 
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Applicative (Applicative)
import Data.Typeable (Typeable)
import qualified Data.Map.Strict as Map 
import Graphics.GL.Core33
import Graphics.GL.Types
import Control.Concurrent.MVar
import Data.IORef
import Control.Monad
import Data.List (delete)
import Foreign.C.Types
import Data.Maybe (maybeToList)

type ContextFactory c ds = ContextFormat c ds -> IO ContextHandle

data ContextHandle = ContextHandle {
    newSharedContext :: forall c ds. ContextFormat c ds -> IO ContextHandle,
    contextDoSync :: forall a. IO a -> IO a,
    contextDoAsync :: IO () -> IO (),
    contextSwap :: IO (),   
    contextFrameBufferSize :: IO (Int, Int),
    contextDelete :: IO ()
} 

newtype ContextT os f m a = 
    ContextT (ReaderT (ContextHandle, (ContextData, SharedContextDatas)) m a) 
    deriving (Functor, Applicative, Monad, MonadIO, MonadException, MonadAsyncException)
    
instance MonadTrans (ContextT os f) where
    lift = ContextT . lift 


runContextT :: (MonadIO m, MonadAsyncException m) => ContextFactory c ds -> ContextFormat c ds -> (forall os. ContextT os (ContextFormat c ds) m a) -> m a
runContextT cf f (ContextT m) = 
    bracket 
        (liftIO $ cf f)
        (liftIO . contextDelete)
        $ \ h -> do cds <- liftIO newContextDatas
                    cd <- liftIO $ addContextData cds
                    let ContextT i = initGlState
                        rs = (h, (cd, cds))
                    runReaderT (i >> m) rs

runSharedContextT :: (MonadIO m, MonadAsyncException m) => ContextFormat c ds -> ContextT os (ContextFormat c ds) (ContextT os f m) a -> ContextT os f m a
runSharedContextT f (ContextT m) =
    bracket
        (do (h',(_,cds)) <- ContextT ask
            h <- liftIO $ newSharedContext h' f
            cd <- liftIO $ addContextData cds
            return (h,cd)
        )
        (\(h,cd) -> do cds <- ContextT $ asks (snd . snd)
                       liftIO $ removeContextData cds cd
                       liftIO $ contextDelete h)
        $ \(h,cd) -> do cds <- ContextT $ asks (snd . snd)
                        let ContextT i = initGlState
                            rs = (h, (cd, cds))
                        runReaderT (i >> m) rs

initGlState :: MonadIO m => ContextT os f m ()
initGlState = liftContextIOAsync $ do glEnable GL_FRAMEBUFFER_SRGB
                                      glEnable GL_SCISSOR_TEST
                                      glPixelStorei GL_PACK_ALIGNMENT 1
                                      glPixelStorei GL_UNPACK_ALIGNMENT 1

liftContextIO :: MonadIO m => IO a -> ContextT os f m a
liftContextIO m = ContextT (asks fst) >>= liftIO . flip contextDoSync m

addContextFinalizer :: MonadIO m => IORef a -> IO () -> ContextT os f m ()
addContextFinalizer k m = ContextT (asks fst) >>= liftIO . void . mkWeakIORef k . flip contextDoAsync m

getContextFinalizerAdder  :: MonadIO m =>  ContextT os f m (IORef a -> IO () -> IO ())
getContextFinalizerAdder = do h <- ContextT (asks fst)
                              return $ \k m -> void $ mkWeakIORef k (contextDoAsync h m)  

liftContextIOAsync :: MonadIO m => IO () -> ContextT os f m ()
liftContextIOAsync m = ContextT (asks fst) >>= liftIO . flip contextDoAsync m

swapContextBuffers :: MonadIO m => ContextT os f m ()
swapContextBuffers = ContextT (asks fst) >>= (\c -> liftIO $ contextDoSync c $ contextSwap c)

newtype Render os f a = Render (ReaderT (ContextHandle, (ContextData, SharedContextDatas)) IO a) deriving (Monad, Applicative, Functor)

render :: (MonadIO m, MonadException m) => Render os f () -> ContextT os f m ()
render (Render m) = ContextT ask >>= (\c -> liftIO $ contextDoAsync (fst c) $ runReaderT m c)

getContextBuffersSize :: Render os f (Int, Int)
getContextBuffersSize = Render (asks fst >>= lift . contextFrameBufferSize)

getRenderContextFinalizerAdder  :: Render os f (IORef a -> IO () -> IO ())
getRenderContextFinalizerAdder = do h <- Render (asks fst)
                                    return $ \k m -> void $ mkWeakIORef k (contextDoAsync h m)  

data GPipeException = GPipeException String
     deriving (Show, Typeable)

instance Exception GPipeException


-- TODO Add async rules     
{-# RULES
"liftContextIO >>= liftContextIO >>= x"    forall m1 m2 x.  liftContextIO m1 >>= (\_ -> liftContextIO m2 >>= x) = liftContextIO (m1 >> m2) >>= x
"liftContextIO >>= liftContextIO"          forall m1 m2.    liftContextIO m1 >>= (\_ -> liftContextIO m2) = liftContextIO (m1 >> m2)
  #-}

--------------------------

type SharedContextDatas = MVar [ContextData]
type ContextData = MVar (VAOCache, FBOCache)
data VAOKey = VAOKey { vaoBname :: !GLuint, vaoCombBufferOffset :: !Int, vaoComponents :: !GLint, vaoNorm :: !Bool, vaoDiv :: !Int } deriving (Eq, Ord)
data FBOKey = FBOKey { fboTname :: !GLuint, fboTlayerOrNegIfRendBuff :: !Int, fboTlevel :: !Int } deriving (Eq, Ord)
data FBOKeys = FBOKeys { fboColors :: [FBOKey], fboDepth :: Maybe FBOKey, fboStencil :: Maybe FBOKey } deriving (Eq, Ord)  
type VAOCache = Map.Map [VAOKey] (IORef GLuint)
type FBOCache = Map.Map FBOKeys (IORef GLuint)

getFBOKeys :: FBOKeys -> [FBOKey]
getFBOKeys (FBOKeys xs d s) = xs ++ maybeToList d ++ maybeToList s

newContextDatas :: IO (MVar [ContextData])
newContextDatas = newMVar []

addContextData :: SharedContextDatas -> IO ContextData
addContextData r = do cd <- newMVar (Map.empty, Map.empty)  
                      modifyMVar_ r $ return . (cd:)
                      return cd

removeContextData :: SharedContextDatas -> ContextData -> IO ()
removeContextData r cd = modifyMVar_ r $ return . delete cd

addCacheFinalizer :: MonadIO m => (GLuint -> (VAOCache, FBOCache) -> (VAOCache, FBOCache)) -> IORef GLuint -> ContextT os f m ()
addCacheFinalizer f r =  ContextT $ do cds <- asks (snd . snd)
                                       liftIO $ do n <- readIORef r
                                                   void $ mkWeakIORef r $ do cs' <- readMVar cds 
                                                                             mapM_ (`modifyMVar_` (return . f n)) cs'

addVAOBufferFinalizer :: MonadIO m => IORef GLuint -> ContextT os f m ()
addVAOBufferFinalizer = addCacheFinalizer deleteVAOBuf  
    where deleteVAOBuf n (vao, fbo) = (Map.filterWithKey (\k _ -> all ((/=n) . vaoBname) k) vao, fbo)

    
addFBOTextureFinalizer :: MonadIO m => Bool -> IORef GLuint -> ContextT os f m ()
addFBOTextureFinalizer isRB = addCacheFinalizer deleteVBOBuf    
    where deleteVBOBuf n (vao, fbo) = (vao, Map.filterWithKey
                                          (\ k _ ->
                                             all
                                               (\ fk ->
                                                  fboTname fk /= n || isRB /= (fboTlayerOrNegIfRendBuff fk < 0))
                                               $ getFBOKeys k)
                                          fbo)


getContextData :: MonadIO m => ContextT os f m ContextData
getContextData = ContextT $ asks (fst . snd)

getRenderContextData :: Render os f ContextData
getRenderContextData = Render $ asks (fst . snd)

getVAO :: ContextData -> [VAOKey] -> IO (Maybe (IORef GLuint))
getVAO cd k = do (vaos, _) <- readMVar cd
                 return (Map.lookup k vaos)    

setVAO :: ContextData -> [VAOKey] -> IORef GLuint -> IO ()
setVAO cd k v = modifyMVar_ cd $ \ (vaos, fbos) -> return (Map.insert k v vaos, fbos)  

getFBO :: ContextData -> FBOKeys -> IO (Maybe (IORef GLuint))
getFBO cd k = do (_, fbos) <- readMVar cd
                 return (Map.lookup k fbos)

setFBO :: ContextData -> FBOKeys -> IORef GLuint -> IO ()
setFBO cd k v = modifyMVar_ cd $ \(vaos, fbos) -> return (vaos, Map.insert k v fbos)  
