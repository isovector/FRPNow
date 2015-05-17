
module Lib.EventStream
(Stream, next, nextSim, repeatEv, merge, fmapB, filterJusts, zipBS, filterEv, filterMapB, toChanges, delayDiscrete, delayDiscreteN, asChanges,
  filterB, during,sampleOn, scanlEv, filterStream, foldr1Ev, foldrEv, foldrSwitch, foldB, fold, parList, bufferStream, fromChanges,
 callbackStream, callStream, callSyncIOStream, printAll)
  where

import Data.Maybe
import Control.Monad hiding (when)
import Control.Applicative hiding (empty)
import Data.IORef
import Data.Sequence hiding (reverse,scanl,take,drop)
import Prelude hiding (until,length)
import qualified Prelude as P
import Debug.Trace
--import Control.Concurrent.MVar

import Swap
import Impl.WXFRPNow
import Lib.Lib
import Debug.Trace

newtype Stream a = S { getEs :: Behavior (Event [a]) }

instance Functor Stream where
  fmap f (S b) = S $ (fmap f <$>) <$> b

next :: Stream a -> B (E a)
next s = (head <$>) <$> (nextSim s)

nextSim :: Stream a -> Behavior (Event [a])
nextSim e = unsafeLazy $  getEs e

dropStream :: Int -> Stream a -> Behavior (Stream a)
dropStream n s =
  do e <- nextSim s
     e' <- join <$> plan (nxt n <$> e)
     return (S $ pure e' `switch` (getEs s <$ e')) 
 where
   nxt n l = 
     let m = P.length l 
     in if m > n 
        then pure (pure (drop n l))
        else if n == 0
             then nextSim s
             else do e <- nextSim s
                     join <$> plan (nxt (n - m) <$> e)
                      

delayDiscreteN :: Int -> Stream a -> Behavior (Stream a)
delayDiscreteN n s = 
  do x <- scanlEv (\l x -> take n (x:l)) [] s
     x' <- dropStream n x
     return (last <$> x')

tailStream :: Stream a -> Behavior (Stream a)
tailStream s = S <$> 
     do e <- nextSim s
        e' <- join <$> plan (nxt <$> e)
        return (pure e' `switch` (getEs s <$ e')) where
  nxt [h]   = nextSim s
  nxt (h:t) = pure (pure t)
              
delayDiscrete :: Stream a -> Behavior (Stream a)
delayDiscrete s = do x <- scanlEv (\(_,p) x -> (p,x)) (undefined,undefined) s
                     x' <- tailStream x
                     return (fst <$> x')


repeatEv :: Behavior (Event a) -> Stream a
repeatEv b = S $ loop where
   loop = do e <- b
             let e' = (\x -> [x]) <$> e
             pure e' `switch` (loop <$ e)

-- in case of simultaneity, the left elements come first
merge :: Stream a -> Stream a -> Stream a
merge l r = loop where
  loop = S $
   do l' <- nextSim l
      r' <- nextSim r
      e <- fmap nxt <$> race l' r'
      let again = nextSim loop
      pure e `switch` fmap (const again) e
  nxt (Tie  l r) = l ++ r
  nxt (L    l  ) = l
  nxt (R      r) = r



fmapB :: Behavior (a -> b) -> Stream a -> Stream b
fmapB f es = S $ loop where
 loop =  do e  <- nextSim es
            plan (nxt <$> e)
 nxt l = (<$> l) <$> f

zipBS :: Behavior a -> Stream b -> Stream (a,b)
zipBS f es = S $ loop where
 loop =  do e  <- next es
            plan (nxt <$> e)
 nxt l = (\x -> [(x,l)]) <$> f


nextJusts :: Stream (Maybe a) -> Behavior (Event [a])
nextJusts es = loop where
  loop =
    do e <- nextSim es
       join <$> plan (fmap nxt e)
  nxt l = case catMaybes l of
              [] -> loop
              l  -> return (return l)

filterStream :: (a -> Bool) -> Stream a -> Stream a
filterStream f s = filterJusts (toMaybef <$> s)
  where toMaybef x | f x = Just x
                   | otherwise = Nothing

filterJusts :: Stream (Maybe a) -> Stream a
filterJusts es = S $ nextJusts es

filterEv :: Stream Bool -> Stream ()
filterEv es = filterJusts (toJust <$> es)
  where toJust True = Just ()
        toJust False = Nothing


filterMapB :: Behavior (a -> Maybe b) -> Stream a -> Stream b
filterMapB f e = filterJusts $ fmapB f e

filterB :: Behavior (a -> Bool) -> Stream a -> Stream a
filterB f = filterMapB (toMaybe <$> f)
  where toMaybe f = \a ->  if f a then Just a else Nothing

during :: Stream a -> Behavior Bool -> Stream a
e `during` b = filterB (const <$> b) e

sampleOn :: Behavior a -> Stream x -> Stream a
sampleOn b s = S loop where
 loop = do e  <- nextSim s
           let singleton x = [x]
           plan ((singleton <$> b) <$ e)


scanlEv :: (a -> b -> a) -> a -> Stream b -> Behavior (Stream a)
scanlEv f i es = S <$> loop i where
 loop i =
  do e  <- nextSim es
     let e' = (\(h : t) -> tail $ scanl f i (h : t)) <$> e
     ev <- plan (loop . last <$> e')
     return (pure e' `switch` ev)

foldr1Ev :: (a -> Event b -> b) -> Stream a -> Behavior (Event b)
foldr1Ev f es = loop where
 loop =
  do e  <- nextSim es
     plan (nxt <$> e)
 nxt [h]     = f h          <$> loop
 nxt (h : t) = f h . return <$> nxt t

foldrEv :: a -> (a -> Event b -> b) -> Stream a -> Behavior b
foldrEv i f es = f i <$> foldr1Ev f es

foldrSwitch :: Behavior a -> Stream (Behavior a) -> Behavior (Behavior a)
foldrSwitch b = foldrEv b switch

foldBs :: Behavior a -> (Behavior a -> b -> Behavior a) -> Stream b -> Behavior (Behavior a)
foldBs b f es = scanlEv f b es >>= foldrSwitch b
{-
repeatIO :: IO a -> Now (Stream a)
repeatIO m = S <$> loop where
  loop = do  h  <- async m
             t  <- planNow (loop <$ h)
             return (pure ((\x -> [x]) <$> h) `switch` t)

repeatIOList :: IO [a] -> Now (Stream a)
repeatIOList m = S <$> loop where
  loop = do  h  <- async m
             t  <- planNow (loop <$ h)
             return (pure h `switch` t)
-}
catMaybesStream :: Stream (Maybe a) -> Stream a
catMaybesStream s = S $ loop where
  loop = do  e <- nextSim s
             join <$> plan (nxt <$> e)
  nxt l = case  catMaybes l of
             [] -> loop
             l  -> return (return l)

snapshots :: B a -> Stream () -> Stream a
snapshots b s = S $
  do  e       <- nextSim s
      ((\x -> [x]) <$>) <$> snapshot b (head <$> e)

fold :: (a -> b -> a) -> a -> Stream b -> Behavior (Behavior a)
fold f i s = loop i where
  loop i = do e  <- nextSim s
              let e' = foldl f i <$> e
              ev <- plan (loop <$> e')
              return (i `step` ev)

parList :: Stream (BehaviorEnd b ()) -> Behavior (Behavior [b])
parList = foldBs (pure []) (flip (.:))

bufferStream :: Int -> Stream a -> Behavior (Stream [a])
bufferStream i = scanlEv (\t h -> take i (h : t)) []

fromChanges :: Eq a => Behavior a -> Stream a
fromChanges = repeatEv . changeVal

asChanges :: a -> Stream a -> Behavior (Behavior a)
asChanges i s = loop i where
  loop i = do e  <- nextSim s
              e' <- plan (loop . last <$> e)
              return (i `step` e')

toChanges :: a -> Stream a -> Now (Behavior a)
toChanges i s = loop i where
  loop i = do e  <- sample (nextSim s)
              e' <- plan (loop . last <$> e)
              return (i `step` e')


-- give an event stream that has an event each time the
-- returned function is called
-- useful for interfacing with callback-based
-- systems
callbackStream :: Now (Stream a, a -> IO ())
callbackStream = do mv <- syncIO $ newIORef ([], Nothing)
                    (_,s) <- loop mv
                    return (S s, func mv) where
  loop mv =
         do -- unsafeSyncIO $ traceIO "take2"
            (l, Nothing) <- syncIO $ readIORef mv
            (e,cb) <- callbackE
            syncIO $ writeIORef mv ([], Just cb)
            -- unsafeSyncIO $ traceIO "rel2"
            es <- planNow $ loop mv <$ e
            let h = fst <$> es
            let t = snd <$> es
            return (reverse l, h `step` t)

  func mv x =
    do -- traceIO "take"
       (l,mcb) <- readIORef mv
       writeIORef mv (x:l, Nothing)
       -- traceIO "release!"
       case mcb of
         Just x -> x ()
         Nothing -> return ()


-- call the given function each time an event occurs
callStream :: ([a] -> Now (Event ())) -> Stream a -> Now ()
callStream f evs = do e2 <- sample (nextSim evs)
                      planNow (again <$>  e2)
                      return () where
  again a = do e2 <- f a
               e <- sample (nextSim evs)
               planNow (again <$> (e2 >> e))
               return ()
{-
callIOStream :: (a -> IO ()) -> Stream a -> Now ()
callIOStream f = callStream (\x -> async (mapM_ f x))
-}
callSyncIOStream :: (a -> IO ()) -> Stream a -> Now ()
callSyncIOStream f = callStream (\x -> syncIO (mapM_ f x) >> return (pure ()))

printAll :: (Show a, Eq a) => Stream a -> Now ()
printAll = callSyncIOStream (\x -> traceIO (show x))
{-
-- See reflection without remorse for which performance problem this construction solves...

type Evs     x = Seq (EvsView x)
type EvsView x = Event (EH x)
data EH x = x :| Evs x | End


toView :: Evs x -> EvsView x
toView e = case viewl e of
     EmptyL -> return End
     h :< t -> h >>= nxt t
  where nxt t End = toView t
        nxt r (h :| l) = let q = l >< r in return (h :| q)

append :: Evs x -> Evs x -> Evs x
append = (><)

app :: Evs x -> Event (Evs x) -> Evs x
app l r = append l (singleton $ join $ fmap toView r) -- it's magic!

emptyEmits = empty
singleEmit x = singleton (return (x :| emptyEmits))

toStream :: Evs x -> Stream x
toStream = Es . loop where
  loop e = do e' <- lose e
              eh <- join <$> plan (nxt [] <$> toView e')
              pure eh `switch` (loop e' <$ eh)
  lose e = getNow (toView e) >>= \case
            Just End      -> return emptyEmits
            Just (h :| t) -> lose t
            Nothing       -> return e
  nxt :: [x] -> EH x -> Behavior (Event ([x]))
  nxt [] End     = return never
  nxt l  End     = return (return (reverse l))
  nxt l (h :| t) = getNow (toView t) >>= \case
                    Just x -> nxt (h : l) x
                    Nothing -> return (return (reverse (h: l)))

data StreamM x a = StreamM { emits :: Evs x, eend :: Event a }

instance Monad (StreamM x) where
  return x = StreamM emptyEmits (return x)
  (StreamM s e) >>= f = let fv = fmap f e
                                 fs = emits <$> fv
                                 fa = fv >>= eend
                             in StreamM (app s fs) fa

emit :: (Swap (BehaviorEnd x) f, Monad f) =>  x -> (f :. StreamM x) ()
emit x = liftRight $ StreamM (singleEmit x) (return ())

instance Wait (StreamM x) where
  waitEv = StreamM emptyEmits

instance (Monad b, Swap Event b) => Swap (StreamM x) b where
  swap (StreamM b e) = liftM (StreamM b) (plan e)

instance Functor (StreamM x) where fmap = liftM
instance Applicative (StreamM x) where pure = return ; (<*>) = ap

runStreamM :: StreamM x a -> (Stream x, Event a)
runStreamM (StreamM s e) = (toStream s, e)


-}
