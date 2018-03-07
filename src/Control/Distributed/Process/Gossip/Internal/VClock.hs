module Control.Distributed.Process.Gossip.Internal.VClock (VClock
              , Relation(..)
              , empty
              , insert
              , fromList
              , toList
              , lookup
              , inc
              , incDefault
              , merge
              , relates
              ) where

import Data.Foldable (Foldable(foldMap), foldl')
import Prelude hiding (lookup)
import Data.Binary
import qualified Prelude as P (lookup)

newtype VClock a b = VClock [(a, b)]
    deriving (Show, Eq)

instance (Ord a, Ord b, Binary a, Binary b) => Binary (VClock a b) where
    put = put . toList
    get = get >>= \lst -> return $ fromList lst

data Relation = Same | Before | After | Concurrent
    deriving (Show,Eq)

instance Foldable (VClock a) where
    foldMap f (VClock vc) = foldMap f (map snd vc)

empty :: (Ord a) => VClock a b
empty = VClock []

insert :: (Ord a, Ord b) => (a, b) -> VClock a b -> VClock a b
insert (k, v) (VClock vc) = VClock $ go vc
    where go [] = [(k,v)]
          go (vc'@(k',v') : vcs')
            | k' < k    = vc' : go vcs' 
            | k' == k   = (if v >= v' then (k, v) else (k, v')) : vcs'
            | otherwise = (k, v) : vc' : vcs'

fromList :: (Ord a, Ord b) => [(a, b)] -> VClock a b
fromList = foldl' (flip insert) empty

toList :: VClock a b -> [(a,b)]
toList (VClock d) = d

lookup :: (Ord a) => a -> VClock a b -> Maybe b
lookup key (VClock vc) = P.lookup key vc

inc :: (Ord a, Ord b, Num b) => a -> VClock a b -> VClock a b
inc k c = case lookup k c of
            Just v -> insert (k, v + 1) c
            Nothing -> c

incDefault :: (Ord a, Ord b, Num b) => a -> b -> VClock a b -> VClock a b
incDefault k d c = case lookup k c of
                     Just v -> inc k c
                     Nothing -> insert (k, d) c

merge :: (Ord a, Ord b) => VClock a b -> VClock a b -> VClock a b
merge (VClock vc1) other = foldl' (flip insert) other vc1 

relates :: (Ord a, Ord b) => VClock a b -> VClock a b -> Relation
relates (VClock c1) (VClock c2) = relates' c1 c2 Same
    where relates' [] [] s = s
          relates' [] c2s s = if s == After then Concurrent else Before
          relates' c1s [] s = if s == Before then Concurrent else After
          relates' ((k1,v1):c1s) ((k2,v2):c2s) s = 
              case compare k1 k2 of
                EQ -> case compare v1 v2 of
                        EQ -> relates' c1s c2s s
                        LT -> if s == After  then Concurrent else relates' c1s c2s Before
                        _  -> if s == Before then Concurrent else relates' c1s c2s After
                LT -> case s of
                        Before -> Concurrent
                        _      -> relates' c1s ((k2,v2):c2s) After
                GT -> case s of
                        After -> Concurrent
                        _     -> relates' ((k1,v2):c1s) c2s Before
 
