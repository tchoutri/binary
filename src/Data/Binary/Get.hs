{-# LANGUAGE CPP, RankNTypes, MagicHash, BangPatterns #-}

-- CPP C style pre-precessing, the #if defined lines
-- RankNTypes forall r. statement
-- MagicHash the (# unboxing #), also needs GHC.primitives

module Data.Binary.Get (

    -- * The Get type
      Get
    , Result(..)
    , runGet
    , runGetPartial
    , runGetState -- DEPRECATED

    , feed
    , eof


    -- * Parsing
    , skip
    , lookAhead

    -- * Utility
    , bytesRead
    , remaining
    , getBytes
    , isEmpty

    -- * Parsing particular types
    , getWord8
    
    -- ** ByteStrings
    , getByteString
    , getLazyByteString
    -- , getLazyByteStringNul
    -- , getRemainingLazyByteString

    -- ** Big-endian reads
    , getWord16be
    , getWord32be
    , getWord64be

    -- ** Little-endian reads
    , getWord16le
    , getWord32le
    , getWord64le

    -- ** Host-endian, unaligned reads
    , getWordhost
    , getWord16host
    , getWord32host
    , getWord64host


    ) where

import Foreign
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Lazy as L

import Control.Applicative

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
-- needed for (# unboxing #) with magic hash
import GHC.Base
import GHC.Word
-- import GHC.Int
#endif

-- Kolmodin 20100427: at zurihac we discussed of having partial take a
-- "Maybe ByteString" and implemented it in this way.
-- The reasoning was that you could accidently provide an empty bytestring,
-- and it should not terminate the parsing (empty would mean eof).
-- However, I'd say that it's also a risk that you get stuck in a loop,
-- where you keep providing an empty string. Anyway, no new input should be
-- rare, as the RTS should only wake you up if you actually have some data
-- to read from your fd.

-- | The result of parsing.
data Result a = Fail B.ByteString Int64 String
              -- ^ The parser ran into an error. The parser either used
              -- 'fail' or was not provided enough input.
              | Partial (Maybe B.ByteString -> Result a)
              -- ^ The parser has consumed the available input and needs
              -- more to continue. Provide 'Just' if more input is available
              -- and 'Nothing' otherwise, and you will get a new 'Result'.
              | Done B.ByteString Int64 a
              -- ^ The parser has successfully finished. Except for the
              -- output value you also get the unused input as well as the
              -- count of used bytes.

-- unrolled codensity/state monad
newtype Get a = C { runCont :: forall r.
                               B.ByteString ->
                               Int64 ->
                               Success a r ->
                               Result    r }

type Success a r = B.ByteString -> Int64 -> a -> Result r

instance Monad Get where
  return = returnG
  (>>=) = bindG
  fail = failG

returnG :: a -> Get a
returnG a = C $ \s pos ks -> ks s pos a
{-# INLINE [0] returnG #-}

bindG :: Get a -> (a -> Get b) -> Get b
bindG (C c) f = C $ \i pos ks -> c i pos (\i' pos a -> (runCont (f a)) i' pos ks)
{-# INLINE bindG #-}

failG :: String -> Get a
failG str = C $ \i pos _ks -> Fail i pos str

{-
apG :: Get (a -> b) -> Get a -> Get b
apG d e = do
  b <- d
  a <- e
  return (b a)
{-# INLINE apG #-}
-}

apG :: Get (a -> b) -> Get a -> Get b
apG (C f) (C a) = C $ \i pos ks -> f i pos (\i' pos' f' -> a i' pos' (\i'' pos'' a' -> ks i'' pos'' (f' a')))
{-# INLINE [0] apG #-}

fmapG :: (a -> b) -> Get a -> Get b
fmapG f m = C $ \i pos ks -> runCont m i pos (\i' pos' a -> ks i' pos' (f a))
{-# INLINE fmapG #-}

instance Applicative Get where
  pure = returnG
  {-# INLINE pure #-}
  (<*>) = apG
  {-# INLINE (<*>) #-}

instance Functor Get where
  fmap = fmapG

instance Functor Result where
  fmap f (Done s p a) = Done s p (f a)
  fmap f (Partial c) = Partial (\bs -> fmap f (c bs))
  fmap _ (Fail s p msg) = Fail s p msg

instance (Show a) => Show (Result a) where
  show (Fail _ p msg) = "Fail at position " ++ show p ++ ": " ++ msg
  show (Partial _) = "Partial _"
  show (Done s p a) = "Done at position " ++ show p ++ ": " ++ show a

-- | DEPRECATED. Provides compatibility with previous versions of this library.
-- Run a 'Get' monad and provide both all the input and an initial position.
-- Additional to the result of get it returns the number of consumed bytes
-- and the unconsumed input.
--
{-# DEPRECATED runGetState "Use runGetPartial instead. This function will be removed." #-}
runGetState :: Get a -> L.ByteString -> Int64 -> (a, L.ByteString, Int64)
runGetState g lbs p = go (runCont g B.empty p (\i p a -> Done i p a))
                         (L.toChunks lbs)
  where
  go (Done s p a) lbs   = (a, L.fromChunks (s:lbs), p)
  go (Partial f) (x:xs) = go (f $ Just x) xs
  go (Partial f) []     = go (f Nothing) []
  go (Fail _ _ msg)   _ = error ("Data.Binary.Get.runGetState: " ++ msg)


-- | Run a 'Get' monad. See 'Result' for what to do next, like providing
-- input, handling parser errors and to get the output value.
runGetPartial :: Get a -> Result a
runGetPartial g = noMeansNo $
  runCont g B.empty 0 (\i p a -> Done i p a)

-- | Make sure we don't have to pass Nothing to a Partial twice.
-- This way we don't need to pass around an EOF value in the Get monad, it
-- can safely ask several times if it needs to.
noMeansNo :: Result a -> Result a
noMeansNo r0 = go r0
  where
  go r =
    case r of
      Partial f -> Partial $ \ms ->
                    case ms of
                      Just _ -> go (f ms)
                      Nothing -> neverAgain (f ms)
      _ -> r
  neverAgain r =
    case r of
      Partial f -> neverAgain (f Nothing)
      _ -> r

-- | The simplest interface to run a 'Get' parser, also compatible with
-- previous versions of the binary library. If the parser runs into an
-- error, calling 'fail' or running out of input, it will call 'error'.
runGet :: Get a -> L.ByteString -> a
runGet g bs = feedAll (runGetPartial g) chunks
  where
  chunks = L.toChunks bs
  feedAll (Done _ _ r) _ = r
  feedAll (Partial c) (x:xs) = feedAll (c (Just x)) xs
  feedAll (Partial c) [] = feedAll (c Nothing) []
  feedAll (Fail _ _ msg) _ = error msg

-- | Feed a 'Result' with more input. If the 'Result' is 'Done' or 'Fail' it
-- will add the input to 'ByteString' of unconsumed input.
--
-- @
--    'runGetPartial' myParser `feed` myInput1 `feed` myInput2
-- @
feed :: Result a -> B.ByteString -> Result a
feed r inp =
  case r of
    Done inp0 p a -> Done (inp0 `B.append` inp) p a
    Partial f -> f (Just inp)
    Fail inp0 p s -> Fail (inp0 `B.append` inp) p s

-- | Tell a 'Result' that there is no more input.
eof :: Result a -> Result a
eof r =
  case r of
    Done _ _ _ -> r
    Partial f -> f Nothing
    Fail _ _ _ -> r
 
prompt :: B.ByteString -> Result a -> (B.ByteString -> Result a) -> Result a
prompt inp kf ks =
    let loop =
         Partial $ \sm ->
           case sm of
             Just s | B.null s -> loop
                    | otherwise -> ks (inp `B.append` s)
             Nothing -> kf
    in loop

-- | Need more data.
demandInput :: Get ()
demandInput = C $ \inp pos ks ->
  prompt inp (Fail inp pos "demandInput: not enough bytes") (\inp' -> ks inp' pos ())

skip :: Int -> Get ()
skip n = readN n (const ())
{-# INLINE skip #-}

isEmpty :: Get Bool
isEmpty = C $ \inp pos ks ->
    if B.null inp
      then prompt inp (ks inp pos True) (\inp' -> ks inp' pos False)
      else ks inp pos False

{-# DEPRECATED getBytes "Use 'getByteString' instead of 'getBytes'" #-}
getBytes :: Int -> Get B.ByteString
getBytes = getByteString
{-# INLINE getBytes #-}

lookAhead :: Get a -> Get a
lookAhead g = C $ \inp pos ks ->
  let r0 = runGetPartial g `feed` inp
      go acc r = case r of
                    Done _ _ a -> ks (B.concat (inp : reverse acc)) pos a
                    Partial f -> Partial $ \minp -> go (maybe acc (:acc) minp) (f minp)
                    Fail inp' p s -> Fail inp' p s
  in go [] r0

-- | Get the remaining input from the user by multiple Partial and count the
-- bytes. Not recommended as it forces the remaining input and keeps it in
-- memory.
remaining :: Get Int64
remaining = C $ \ inp pos ks ->
  let loop acc = Partial $ \ minp ->
                  case minp of
                    Nothing -> let all = B.concat (inp : (reverse acc))
                               in ks all pos (fromIntegral $ B.length all)
                    Just inp' -> loop (inp':acc)
  in loop []

-- | Returns the total number of bytes read so far.
bytesRead :: Get Int64
bytesRead = C $ \inp pos ks -> ks inp pos pos
------------------------------------------------------------------------
-- ByteStrings
--

getByteString :: Int -> Get B.ByteString
getByteString n = readN n (B.take n)
{-# INLINE getByteString #-}

remainingInCurrentChunk :: Get Int
remainingInCurrentChunk = C $ \inp pos ks -> ks inp pos $! (B.length inp)

getLazyByteString :: Int64 -> Get L.ByteString
getLazyByteString n0 =
  let loop n = do
        left <- remainingInCurrentChunk
        if fromIntegral left >= n
          then fmap (:[]) (getByteString (fromIntegral n))
          else do now <- getByteString left
                  demandInput
                  remaining <- loop (n - fromIntegral left)
                  return (now:remaining)
  in fmap L.fromChunks (loop n0)

-- | Return at least @n@ bytes, maybe more. If not enough data is available
-- the computation will escape with 'Partial'.
readN :: Int -> (B.ByteString -> a) -> Get a
readN n f = ensureN n >> unsafeReadN n f
{-# INLINE [1] readN #-}

{-# RULES

"readN/readN merge" forall n m f g.
  apG (readN n f) (readN m g) = readN (n+m) (\bs -> f bs $ g (B.unsafeDrop n bs))

"returnG/readN swap" forall f.
  returnG f = readN 0 (const f)
 #-}

-- | Ensure that there are at least @n@ bytes available. If not, the computation will escape with 'Partial'.
ensureN :: Int -> Get ()
ensureN n = C $ \inp pos ks -> do
  if B.length inp >= n
    then ks inp pos ()
    else runCont (go n) inp pos ks
  where -- might look a bit funny, but plays very well with GHC's inliner
        -- GHC won't inline recursive functions, so we make ensureN non-recursive
    go n = C $ \inp pos ks -> do
      if B.length inp >= n
        then ks inp pos ()
        else runCont (demandInput >> go n) inp pos ks
{-# INLINE ensureN #-}

unsafeReadN :: Int -> (B.ByteString -> a) -> Get a
unsafeReadN n f = C $ \inp pos ks -> do
  let !pos' = pos + fromIntegral n
  ks (B.unsafeDrop n inp) pos' (f inp)
{- INLINE unsafeReadN -}

readNWith :: Int -> (Ptr a -> IO a) -> Get a
readNWith n f = do
    readN n $ \s -> B.inlinePerformIO $ B.unsafeUseAsCString s (f . castPtr)
{-# INLINE readNWith #-}

------------------------------------------------------------------------
-- Primtives

-- helper, get a raw Ptr onto a strict ByteString copied out of the
-- underlying lazy byteString.

getPtr :: Storable a => Int -> Get a
getPtr n = readNWith n peek
{-# INLINE getPtr #-}

-- | Read a Word8 from the monad state
getWord8 :: Get Word8
getWord8 = readN 1 B.unsafeHead
{-# INLINE getWord8 #-}

-- | Read a Word16 in big endian format
getWord16be :: Get Word16
getWord16be =
    readN 2 $ \s ->
        (fromIntegral (s `B.unsafeIndex` 0) `shiftl_w16` 8) .|.
        (fromIntegral (s `B.unsafeIndex` 1))
{-# INLINE getWord16be #-}

-- | Read a Word16 in little endian format
getWord16le :: Get Word16
getWord16le =
    readN 2 $ \s ->
              (fromIntegral (s `B.unsafeIndex` 1) `shiftl_w16` 8) .|.
              (fromIntegral (s `B.unsafeIndex` 0) )
{-# INLINE getWord16le #-}

-- | Read a Word32 in big endian format
getWord32be :: Get Word32
getWord32be = do
    readN 4 $ \s ->
              (fromIntegral (s `B.unsafeIndex` 0) `shiftl_w32` 24) .|.
              (fromIntegral (s `B.unsafeIndex` 1) `shiftl_w32` 16) .|.
              (fromIntegral (s `B.unsafeIndex` 2) `shiftl_w32`  8) .|.
              (fromIntegral (s `B.unsafeIndex` 3) )
{-# INLINE getWord32be #-}

-- | Read a Word32 in little endian format
getWord32le :: Get Word32
getWord32le = do
    readN 4 $ \s ->
              (fromIntegral (s `B.unsafeIndex` 3) `shiftl_w32` 24) .|.
              (fromIntegral (s `B.unsafeIndex` 2) `shiftl_w32` 16) .|.
              (fromIntegral (s `B.unsafeIndex` 1) `shiftl_w32`  8) .|.
              (fromIntegral (s `B.unsafeIndex` 0) )
{-# INLINE getWord32le #-}

-- | Read a Word64 in big endian format
getWord64be :: Get Word64
getWord64be = do
    readN 8 $ \s ->
              (fromIntegral (s `B.unsafeIndex` 0) `shiftl_w64` 56) .|.
              (fromIntegral (s `B.unsafeIndex` 1) `shiftl_w64` 48) .|.
              (fromIntegral (s `B.unsafeIndex` 2) `shiftl_w64` 40) .|.
              (fromIntegral (s `B.unsafeIndex` 3) `shiftl_w64` 32) .|.
              (fromIntegral (s `B.unsafeIndex` 4) `shiftl_w64` 24) .|.
              (fromIntegral (s `B.unsafeIndex` 5) `shiftl_w64` 16) .|.
              (fromIntegral (s `B.unsafeIndex` 6) `shiftl_w64`  8) .|.
              (fromIntegral (s `B.unsafeIndex` 7) )
{-# INLINE getWord64be #-}

-- | Read a Word64 in little endian format
getWord64le :: Get Word64
getWord64le = do
    readN 8 $ \s ->
              (fromIntegral (s `B.unsafeIndex` 7) `shiftl_w64` 56) .|.
              (fromIntegral (s `B.unsafeIndex` 6) `shiftl_w64` 48) .|.
              (fromIntegral (s `B.unsafeIndex` 5) `shiftl_w64` 40) .|.
              (fromIntegral (s `B.unsafeIndex` 4) `shiftl_w64` 32) .|.
              (fromIntegral (s `B.unsafeIndex` 3) `shiftl_w64` 24) .|.
              (fromIntegral (s `B.unsafeIndex` 2) `shiftl_w64` 16) .|.
              (fromIntegral (s `B.unsafeIndex` 1) `shiftl_w64`  8) .|.
              (fromIntegral (s `B.unsafeIndex` 0) )
{-# INLINE getWord64le #-}

------------------------------------------------------------------------
-- Host-endian reads

-- | /O(1)./ Read a single native machine word. The word is read in
-- host order, host endian form, for the machine you're on. On a 64 bit
-- machine the Word is an 8 byte value, on a 32 bit machine, 4 bytes.
getWordhost :: Get Word
getWordhost = getPtr (sizeOf (undefined :: Word))
{-# INLINE getWordhost #-}

-- | /O(1)./ Read a 2 byte Word16 in native host order and host endianness.
getWord16host :: Get Word16
getWord16host = getPtr (sizeOf (undefined :: Word16))
{-# INLINE getWord16host #-}

-- | /O(1)./ Read a Word32 in native host order and host endianness.
getWord32host :: Get Word32
getWord32host = getPtr  (sizeOf (undefined :: Word32))
{-# INLINE getWord32host #-}

-- | /O(1)./ Read a Word64 in native host order and host endianess.
getWord64host   :: Get Word64
getWord64host = getPtr  (sizeOf (undefined :: Word64))
{-# INLINE getWord64host #-}

------------------------------------------------------------------------
-- Unchecked shifts

shiftl_w16 :: Word16 -> Int -> Word16
shiftl_w32 :: Word32 -> Int -> Word32
shiftl_w64 :: Word64 -> Int -> Word64

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
shiftl_w16 (W16# w) (I# i) = W16# (w `uncheckedShiftL#`   i)
shiftl_w32 (W32# w) (I# i) = W32# (w `uncheckedShiftL#`   i)

#if WORD_SIZE_IN_BITS < 64
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL64#` i)

#if __GLASGOW_HASKELL__ <= 606
-- Exported by GHC.Word in GHC 6.8 and higher
foreign import ccall unsafe "stg_uncheckedShiftL64"
    uncheckedShiftL64#     :: Word64# -> Int# -> Word64#
#endif

#else
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL#` i)
#endif

#else
shiftl_w16 = shiftL
shiftl_w32 = shiftL
shiftl_w64 = shiftL
#endif
