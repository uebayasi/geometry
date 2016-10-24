{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveFunctor               #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Geometry.Segment
-- Copyright   :  (c) 2016 diagrams-lib team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- This module defines /trails/, translationally invariant paths
-- through space.  Trails form a central part of the diagrams-lib API,
-- so the documentation for this module merits careful study.
--
-- Related modules include:
--
-- * The 'TrailLike' class ("Diagrams.TrailLike") exposes a generic
--   API for building a wide range of things out of trails.
--
-- * 'Path's ("Diagrams.Path") are collections of 'Located'
--   ("Diagrams.Located") trails.
--
-- * Trails are composed of 'Segment's (see "Diagrams.Segment"),
--   though most users should not need to work with segments directly.
--
-----------------------------------------------------------------------------

module Geometry.Segment where
  -- (
  --   -- * ClosedSegent
  --   Segment (..)
  -- , HasSegments (..)
  -- -- , envelopeOf
  -- , traceOf
  -- , crossingsOf
  -- , segmentEnvelope

  -- , ClosingSegment (..)
  -- , U.Vector (..)
  -- , U.MVector (..)

  -- ) where

import           Control.Lens                hiding (at, transform, (<|), (|>))
-- import           Control.Lens.Internal       (noEffect)
import Data.Functor.Contravariant (phantom)
import           Data.Functor.Classes
-- import qualified Data.Foldable               as F
-- import           Data.List                   (maximumBy)
-- import           Data.Ord                    (comparing)
import           Data.Semigroup
-- import qualified Data.Vector.Generic         as G
-- import qualified Data.Vector.Generic.Mutable as M
-- import qualified Data.Vector.Unboxed         as U
-- import qualified Data.Vector.Unboxed.Base    as U
-- import           Data.Word

import           Geometry.Angle
import           Geometry.Envelope
import           Geometry.Located
import           Geometry.Parametric
import           Geometry.Query
-- import           Geometry.Segment
import           Geometry.Space
-- import           Geometry.Trace
-- import           Geometry.Trail              (Line, Loop, SegTree (..),
--                                               Trail' (..), withTrail)
import           Geometry.Transform
-- import           Geometry.TwoD.Path          (Crossings (..))
import           Geometry.TwoD.Transform

import           Linear.Affine
import           Linear.Metric
import           Linear.V2
import           Linear.V3
import           Linear.Vector

import           Control.Applicative         (liftA2)
-- import           Control.Monad               (liftM, liftM2)

-- import           Geometry.TrailLike
import           Geometry.TwoD.Vector hiding (e)
-- import Geometry.Located

import           Prelude                     hiding ((^))
import qualified Prelude
import Numeric.Interval.NonEmpty.Internal (Interval (..))
import qualified Numeric.Interval.Kaucher as K

(^) :: Num a => a -> Int -> a
(^) = (Prelude.^)

------------------------------------------------------------------------
-- Closed segments
------------------------------------------------------------------------

data Segment v n
  = Linear !(v n)
  | Cubic !(v n) !(v n) !(v n)
  deriving (Functor, Eq)

instance Show1 v => Show1 (Segment v) where
  liftShowsPrec x y d seg = case seg of
  -- showsPrec1 d seg = case seg of
    Linear v       -> showParen (d > 10) $
      showString "straight " . liftShowsPrec x y 11 v
    Cubic v1 v2 v3 -> showParen (d > 10) $
      showString "bézier3  " . liftShowsPrec x y 11 v1 . showChar ' '
                             . liftShowsPrec x y 11 v2 . showChar ' '
                             . liftShowsPrec x y 11 v3

instance (Show1 v, Show n) => Show (Segment v n) where
  showsPrec = showsPrec1

instance Each (Segment v n) (Segment v n) (v n) (v n) where
  each f (Linear v) = Linear <$> f v
  each f (Cubic c1 c2 c3) = Cubic <$> f c1 <*> f c2 <*> f c3
  {-# INLINE each #-}

straight :: v n -> Segment v n
straight = Linear
{-# INLINE straight #-}

bezier3 :: v n -> v n -> v n -> Segment v n
bezier3 = Cubic
{-# INLINE bezier3 #-}

type instance V (Segment v n) = v
type instance N (Segment v n) = n
type instance Codomain (Segment v n) = v

class (Metric (V t), OrderedField (N t)) => HasSegments t where

  -- | Fold over the segments in a trail.
  segments :: Fold t (Segment (V t) (N t))

  -- | The offset from the start of the first segment to the end of the
  --   last segment.
  offset :: t -> Vn t
  offset = foldlOf' segments (\off seg -> off ^+^ offset seg) zero

instance (Metric v, OrderedField n) => HasSegments (Segment v n) where
  segments f s = f s
  {-# INLINE segments #-}
  offset (Linear v)    = v
  offset (Cubic _ _ v) = v
  {-# INLINE offset #-}

instance HasSegments a => HasSegments (Located a) where
  segments = located . segments
  {-# INLINE segments #-}
  offset = offset . unLoc
  {-# INLINE offset #-}

instance (HasLinearMap v, Num n) => Transformable (Segment v n) where
  transform !t (Linear v)       = Linear (apply t v)
  transform !t (Cubic v1 v2 v3) = Cubic (apply t v1) (apply t v2) (apply t v3)
  {-# INLINE transform #-}

instance (Additive v, Num n) => Parametric (Segment v n) where
  atParam (Linear x) t       = t *^ x
  atParam (Cubic c1 c2 x2) t =  (3 * t'*t'*t ) *^ c1
                            ^+^ (3 * t'*t *t ) *^ c2
                            ^+^ (    t *t *t ) *^ x2
    where t' = 1-t
  {-# INLINE atParam #-}

instance Num n => DomainBounds (Segment v n)

instance (Additive v, Num n) => EndValues (Segment v n) where
  atStart             = const zero
  {-# INLINE atStart #-}
  atEnd (Linear v)    = v
  atEnd (Cubic _ _ v) = v
  {-# INLINE atEnd #-}

instance (Additive v, Fractional n) => Sectionable (Segment v n) where
  splitAtParam (Linear x1) t = (left, right)
    where left  = straight p
          right = straight (x1 ^-^ p)
          p = lerp t x1 zero
  splitAtParam (Cubic c1 c2 x2) t = (left, right)
    where left  = bezier3 a b e
          right = bezier3 (c ^-^ e) (d ^-^ e) (x2 ^-^ e)
          p = lerp t c2 c1
          a = lerp t c1 zero
          b = lerp t p a
          d = lerp t x2 c2
          c = lerp t d p
          e = lerp t c b
  {-# INLINE splitAtParam #-}

  reverseDomain (Linear x1)      = Linear (negated x1)
  reverseDomain (Cubic c1 c2 c3) = Cubic (c2 ^-^ c3) (c1 ^-^ c3) (negated c2)
  {-# INLINE reverseDomain #-}

instance (Metric v, OrderedField n) => HasArcLength (Segment v n) where

  arcLengthBounded _ (Linear x1) = K.singleton $ norm x1
  arcLengthBounded m s@(Cubic c1 c2 x2)
    | ub - lb < m = K.I lb ub
    | otherwise   = arcLengthBounded (m/2) l + arcLengthBounded (m/2) r
   where (l,r) = s `splitAtParam` 0.5
         ub    = sum (map norm [c1, c2 ^-^ c1, x2 ^-^ c2])
         lb    = norm x2

  arcLengthToParam m s _ | arcLength m s == 0 = 0.5
  arcLengthToParam m s@(Linear {}) len = len / arcLength m s
  arcLengthToParam m s@(Cubic {})  len
    | len `K.elem` K.I (-m/2) (m/2) = 0
    | len < 0              = - arcLengthToParam m (fst (splitAtParam s (-1))) (-len)
    | len `K.elem` slen    = 1
    | len > K.sup slen     = 2 * arcLengthToParam m (fst (splitAtParam s 2)) len
    | len < K.sup llen     = (*0.5) $ arcLengthToParam m l len
    | otherwise            = (+0.5) . (*0.5)
                           $ arcLengthToParam (9*m/10) r (len - K.midpoint llen)
    where (l,r) = s `splitAtParam` 0.5
          llen  = arcLengthBounded (m/10) l
          slen  = arcLengthBounded m s

-- Envelopes -----------------------------------------------------------

cubicEnvelope :: (Metric v, OrderedField n) => v n -> v n -> v n -> v n -> Interval n
cubicEnvelope c1 c2 c3 v
  | a > 0     = I 0 b
  | b > 0     = I a 0
  | otherwise = I a b
  where
    I a b = nodeInterval (c3 `dot` v) (mapNode f quadSol)
    f t = (Cubic c1 c2 c3 `atParam` t) `dot` v
    !quadSol = filterNode (liftA2 (&&) (>0) (<1)) $
                 quadForm' (3 * ((3 *^ c1 ^-^ 3 *^ c2 ^+^ c3) `dot` v))
                           (6 * (((-2) *^ c1 ^+^ c2) `dot` v))
                           ((3 *^ c1) `dot` v)
{-# INLINEABLE [0] cubicEnvelope #-}

segmentEnvelope :: (Metric v, OrderedField n) => Segment v n -> v n -> Interval n
segmentEnvelope !s = \v -> case s of
  Linear l       -> let !x = l `dot` v
                    in  if x < 0 then I x 0 else I 0 x
  Cubic c1 c2 c3 -> cubicEnvelope c1 c2 c3 v
{-# SPECIALISE segmentEnvelope :: Segment V2 Double -> V2 Double -> Interval Double #-}
{-# SPECIALISE segmentEnvelope :: Segment V3 Double -> V3 Double -> Interval Double #-}

instance (Metric v, OrderedField n) => Enveloped (Segment v n) where
  getEnvelope _ = EmptyEnvelope
  {-# INLINE getEnvelope #-}

data Pair a b = Pair !a !b

getB :: Pair a b -> b
getB (Pair _ b) = b

envelopeOf
  :: (InSpace v n t, Metric v, OrderedField n)
  => Fold t (Segment v n)
  -> t
  -> v n
  -> Interval n
envelopeOf l t w = getB $ foldlOf' l f (Pair origin (I 0 0)) t where
  f (Pair p e) seg = Pair (p .+^ offset seg) e'
    where
      e' = combine e (moveBy (view _Point p `dot` w) $ segmentEnvelope seg w)
      --
      combine (I a1 b1) (I a2 b2) = I (min a1 a2) (max b1 b2)
      moveBy n (I a b)            = I (a + n) (b + n)
{-# INLINE envelopeOf #-}

------------------------------------------------------------------------
-- Node
------------------------------------------------------------------------

data Node a
  = None
  | One !a
  | Two !a !a
  deriving Foldable

mapNode :: (a -> b) -> Node a -> Node b
mapNode _ None      = None
mapNode f (One a)   = One (f a)
mapNode f (Two a b) = Two (f a) (f b)
{-# INLINE mapNode #-}

nodeInterval :: Ord a => a -> Node a -> Interval a
nodeInterval a = \case
  None    -> I a a
  One b   -> if a < b then I a b else I b a
  Two b c -> if | a < b -> if | b < c     -> I a c -- a < b < c
                              | c < a     -> I c b -- c < a < b
                              | otherwise -> I a b -- a < b < c
                | a < c                   -> I b c -- b < a < c
                | b < c                   -> I b a -- b < c < a
                | otherwise               -> I c a -- c < b < a
{-# INLINE nodeInterval #-}

maxNode :: Ord a => a -> Node a -> a
maxNode a = \case
  None    -> a
  One b   -> max a b
  Two b c -> max (max a b) c
{-# INLINE maxNode #-}

filterNode :: (a -> Bool) -> Node a -> Node a
filterNode f = \case
  None                -> None
  One a   | f a       -> One a
          | otherwise -> None
  Two a b | f a       -> if f b then Two a b else One a
          | f b       -> One b
          | otherwise -> None
{-# INLINE filterNode #-}

nodeList :: Node a -> [a]
nodeList = \case
  None    -> []
  One a   -> [a]
  Two a b -> [a,b]

-- | The quadratic formula.
quadForm' :: OrderedField n => n -> n -> n -> Node n
quadForm' a b c
    -- There are infinitely many solutions in this case,
    -- so arbitrarily return 0
  | a == 0 && b == 0 && c == 0 = One 0
  | a == 0 && b == 0 = None                -- c /= 0
  | a == 0           = One (-c/b)          -- linear
  | d < 0            = None                -- no real solutions
  | b == 0           = let s = sqrt (-c/a) -- ax^2 + c = 0
                       in  Two s (-s)
  | d == 0           = One (-b/(2*a))      -- multiplicity 2 solution
    -- see http://www.mpi-hd.mpg.de/astrophysik/HEA/internal/Numerical_Recipes/f5-6.pdf
  | otherwise        = Two (q/a) (c/q)
 where
   d = b*b - 4*a*c
   q = -1/2*(b + signum b * sqrt d)
{-# INLINE quadForm' #-}

aboutZero' :: (Ord n, Num n) => n -> n -> Bool
aboutZero' tol n = abs n < tol

------------------------------------------------------------------------
-- Cubic
------------------------------------------------------------------------


-- | Solve the cubic equation ax^3 + bx^2 + cx + d = 0, returning a
--   list of all real roots. First argument is tolerance.
cubForm'' :: OrderedField a => a -> a -> a -> a -> a -> [a]
cubForm'' toler a b c d
  | aboutZero' toler a      = nodeList $ quadForm' b c d

    -- three real roots, use trig method to avoid complex numbers
  | delta >  0              = map trig [0,1,2]

    -- one real root of multiplicity 3
  | delta == 0 && disc == 0 = [ -b/(3*a) ]

    -- two real roots, one of multiplicity 2
  | delta == 0 && disc /= 0 = [ (b*c - 9*a*d)/(2*disc)
                              , (9*a^2*d - 4*a*b*c + b^3)/(a * disc)
                              ]

    -- one real root (and two complex)
  | otherwise               = [-b/(3*a) - cc/(3*a) + disc/(3*a*cc)]

  where
    delta  = 18*a*b*c*d - 4*b*b*b*d + b^2*c*c - 4*a*c*c*c - 27*a*a*d*d
    disc   = 3*a*c - b*b
    qq     = sqrt(-27*(a*a)*delta)
    qq'    | aboutZero' toler disc = max (abs $ qq+xx) (abs $ xx-qq)
           | otherwise             = qq
    cc     = cubert (1/2*(qq' + xx))
    xx     = 2*b*b*b - 9*a*b*c + 27*a^2*d
    p      = disc/(3*a*a)
    q      = xx/(27*a*a*a)
    phi = 1/3*acos(3*q/(2*p)*sqrt(-3/p))
    trig k = 2 * sqrt(-p/3) * cos(phi - 2*k*pi/3) - b/(3*a)
    cubert x | x < 0     = -((-x)**(1/3))
             | otherwise = x**(1/3)



------------------------------------------------------------------------
-- 2D specific
------------------------------------------------------------------------

-- trace ---------------------------------------------------------------

traceOf
  :: (InSpace V2 n t, OrderedField n)
  => Fold t (Segment V2 n)
  -> Point V2 n   -- trail start
  -> t            -- trail
  -> Point V2 n   -- trace start
  -> V2 n         -- trace direction
  -> [n]          -- unsorted list of values
traceOf fold p0 trail p v@(V2 !vx !vy) = view _3 $ foldlOf' fold f (p0,False,[]) trail
  where
    !theta = atan2A' vy vx
    -- !rot   = rotation theta
    !t2    = rotation theta <> translation (p^._Point) <> scaling (1/norm v)

    f (q,_nearStart,ts) (Linear w)
      | x1 == 0 && x2 /= 0 = (q .+^ w, False, ts) -- parallel
      | otherwise          = (q .+^ w, nearEnd, t : ts)
      where
        t  = x3 / x1
        x1 =  v `cross2` w
        x2 = pq `cross2` v
        x3 = pq `cross2` w
        pq  = q .-. p
        nearEnd = t > 0.999

    f (q,nearStart, ts) (Cubic c1 c2 c3) = (q .+^ c3, nearEnd, ts' ++ ts)
      where
        qy = papply t2 q ^. _y
        y1 = apply t2 c1 ^. _y
        y2 = apply t2 c2 ^. _y
        y3 = apply t2 c3 ^. _y
        --
        a  =  3*y1 - 3*y2 + y3
        b  = -6*y1 + 3*y2
        c  =  3*y1
        d  =  qy

        -- if there was an intersecion near the end of the previous
        -- segment, don't look for an intersecion at the beggining of
        -- this one
        startLooking
          | nearStart = 0.0001
          | otherwise = 0
        ts' = filter (liftA2 (&&) (>= startLooking) (<= 1.0001)) (cubForm'' 1e-8 a b c d)

        -- if there's an intersection near the end of the segment, we
        -- don't look for an intersecion near the start of the next
        -- segment
        nearEnd = any (>0.9999) ts'
{-# INLINE traceOf #-}

-- traceOf
--   :: (InSpace V2 n t, OrderedField n)
--   => IndexedFold (Point V2 n) t (Segment V2 n)
--   -> t -- trail
--   -> Point V2 n -- start trace
--   -> V2 n -- trace vector
--   -> SortedList n -- list of values
-- traceOf fld t p v@(V2 !vx !vy) = ifoldrOf fld f mempty t
--   where
--     !theta = atan2A' vy vx
--     !rot   = rotation theta
--     !t2    = rotation theta <> translation (p^._Point) <> scaling (1/norm v)

--     f q (Linear w) l
--       | x1 == 0 && x2 /= 0 = l  -- parallel
--       | otherwise          = l <> unsafeMkSortedList [t] -- intersecting or collinear
--       where
--         t  = x3 / x1
--         x1 =  v `cross2` w
--         x2 = pq `cross2` v
--         x3 = pq `cross2` w
--         pq  = q .-. p

--     f q (Cubic c1 c2 c3) l = l <> mkSortedList ts -- completely wrong
--       where
--         qy = papply t2 q ^. _y
--         y1 = apply t2 c1 ^. _y
--         y2 = apply t2 c2 ^. _y
--         y3 = apply t2 c3 ^. _y
--         --
--         a  =  3*y1 - 3*y2 + y3
--         b  = -6*y1 + 3*y2
--         c  =  3*y1
--         d  =  qy
--         ts = filter (liftA2 (&&) (>= 0) (<= 1)) (cubForm'' 1e-8 a b c d)
-- {-# INLINE traceOf #-}

-- crossings -----------------------------------------------------------

-- | The sum of /signed/ crossings of a path as we travel in the
--   positive x direction from a given point.
--
--     - A point is filled according to the 'Winding' fill rule, if the
--       number of 'Crossings' is non-zero (see 'isInsideWinding').
--
--     - A point is filled according to the 'EvenOdd' fill rule, if the
--       number of 'Crossings' is odd (see 'isInsideEvenOdd').
--
--   This is the 'HasQuery' result for 'Path's, 'Located' 'Trail's and
--   'Located' 'Loops'.
--
-- @
-- 'sample' :: 'Path' 'V2' 'Double'                  -> 'Point' 'V2' 'Double' -> 'Crossings'
-- 'sample' :: 'Located' ('Trail' 'V2' 'Double')       -> 'Point' 'V2' 'Double' -> 'Crossings'
-- 'sample' :: 'Located' ('Trail'' 'Loop' 'V2' 'Double') -> 'Point' 'V2' 'Double' -> 'Crossings'
-- @
--
--   Note that 'Line's have no inside or outside, so don't contribute
--   crossings
newtype Crossings = Crossings Int
  deriving (Show, Eq, Ord, Num, Enum, Real, Integral)

instance Semigroup Crossings where
  Crossings a <> Crossings b = Crossings (a + b)
  {-# INLINE (<>) #-}

instance Monoid Crossings where
  mempty  = Crossings 0
  {-# INLINE mempty  #-}
  mappend = (<>)
  {-# INLINE mappend #-}

-- | Test whether the given point is inside the given path,
--   by testing whether the point's /winding number/ is nonzero. Note
--   that @False@ is /always/ returned for paths consisting of lines
--   (as opposed to loops), regardless of the winding number.
--
-- @
-- 'isInsideWinding' :: 'Path' 'V2' 'Double'                  -> 'Point' 'V2' 'Double' -> 'Bool'
-- 'isInsideWinding' :: 'Located' ('Trail' 'V2' 'Double')       -> 'Point' 'V2' 'Double' -> 'Bool'
-- 'isInsideWinding' :: 'Located' ('Trail'' 'Loop' 'V2' 'Double') -> 'Point' 'V2' 'Double' -> 'Bool'
-- @
isInsideWinding :: HasQuery t Crossings => t -> Point (V t) (N t) -> Bool
isInsideWinding t = (/= 0) . sample t
{-# INLINE isInsideWinding #-}

-- | Test whether the given point is inside the given path,
--   by testing whether a ray extending from the point in the positive
--   x direction crosses the path an even (outside) or odd (inside)
--   number of times.  Note that @False@ is /always/ returned for
--   paths consisting of lines (as opposed to loops), regardless of
--   the number of crossings.
--
-- @
-- 'isInsideEvenOdd' :: 'Path' 'V2' 'Double'                  -> 'Point' 'V2' 'Double' -> 'Bool'
-- 'isInsideEvenOdd' :: 'Located' ('Trail' 'V2' 'Double')       -> 'Point' 'V2' 'Double' -> 'Bool'
-- 'isInsideEvenOdd' :: 'Located' ('Trail'' 'Loop' 'V2' 'Double') -> 'Point' 'V2' 'Double' -> 'Bool'
-- @
isInsideEvenOdd :: HasQuery t Crossings => t -> Point (V t) (N t) -> Bool
isInsideEvenOdd t = odd . sample t
{-# INLINE isInsideEvenOdd #-}


-- | Compute the sum of signed crossings of a trail starting from the
--   given point in the positive x direction.
crossingsOf
  :: (InSpace V2 n t, HasSegments t)
  => IndexedFold (Point V2 n) t (Segment V2 n)
  -> t
  -> Point V2 n
  -> Crossings
crossingsOf l trail p @ (P (V2 _ y)) = ifoldrOf l f 0 trail
  where

    f a @(P(V2 _ ay)) (Linear v@(V2 _ vy)) c
      | ay <= y && vy > 0 && isLeft     = c + 1
      | vy <= 0 && ay > y && not isLeft = c - 1
      | otherwise                       = c
      where isLeft = cross2 v (p .-. a) > 0

    f (P(V2 _ ay)) (Cubic c1@(V2 _ c1y) c2@(V2 _ c2y) c3@(V2 _ c3y)) c
      -- = sum . fmap tTest . filterNode (\t -> t >= 0 && t <= 1) $ ts
      = sum . fmap tTest . filter (\t -> t >= 0 && t <= 1) $ ts
      where
        ts = cubForm'' 1e-8
                     ( 3*c1y - 3*c2y + c3y)
                     (-6*c1y + 3*c2y)
                     ( 3*c1y)
                     (ay - y)
        tTest t = let (V2 vx _) = Cubic c1 c2 c3 `atParam` t
                  in  if vx > 0 then signFromDerivAt t else 0
        signFromDerivAt t =
          let V2 tx ty =  (3*t*t) *^ (3*^c1 ^-^ 3*^c2 ^+^ c3)
                      ^+^ (2*t)   *^ (-6*^c1 ^+^ 3*^c2)
                      ^+^            (3*^c1)
              ang = atan2A' ty tx ^. rad
          in  if | 0   < ang && ang < pi && t < 1 -> c + 1
                 | -pi < ang && ang < 0  && t > 0 -> c - 1
                 | otherwise                      -> c
{-# INLINE crossingsOf #-}

-- | The parameters at which the segment is tangent to the given
--   direction.
paramsTangentTo
  :: OrderedField n
  => V2 n
  -> Fold (Segment V2 n) n
paramsTangentTo
  (V2 tx ty)
  f
  (Cubic (V2 x1 y1) (V2 x2 y2) (V2 x3 y3)) =
  phantom (folded f $ filterNode (\x -> x >= 0 && x <= 1) (quadForm' a b c))
    where
      a = tx*(y3 + 3*(y1 - y2)) - ty*(x3 + 3*(x1 - x2))
      b = 2*(tx*(y2 - 2*y1) - ty*(x2 - 2*x1))
      c = tx*y1 - ty*x1
paramsTangentTo _ _  (Linear {}) = undefined

splitAtParams
  :: (Metric v, OrderedField n) => Segment v n -> [n] -> [Segment v n]
splitAtParams = go 1 where
  go !_ seg []     = [seg]
  go t0 seg (t:ts) = s1 : go t' s2 ts
    where
      (s1,s2) = seg `splitAtParam` (t - t0)
      t' = (t - t0) / (1 - t0)

  -- section x t1 t2 = snd (splitAtParam (fst (splitAtParam x t2)) (t1/t2))
  -- section s0 t1 t2 = snd (splitAtParam (fst (splitAtParam x t2)) (t1/t2))
  --   where
  --     (_,s1) = s0 `splitAtParam` t1
  --     (s2,_) = s1 `splitAtParam` m'


-- | Return False if some points fall outside a line with a thickness of
--   the given tolerance.  fat line calculation taken from the
--   bezier-clipping algorithm (Sederberg)
colinear :: OrderedField n => n -> Segment V2 n -> Bool
colinear _   Linear {} = True
colinear eps (Cubic c1 c2 c3) = dmax - dmin < eps
  where
    d1 = distance c1 c3
    d2 = distance c2 c3
    (dmin, dmax) | d1*d2 > 0 = (3/4 * minimum [0, d1, d2],
                                3/4 * maximum [0, d1, d2])
                 | otherwise = (4/9 * minimum [0, d1, d2],
                                4/9 * maximum [0, d1, d2])
{-# INLINE colinear #-}

-- | Check if two segments are approximately equal.
segmentsEqual
  :: OrderedField n
  => n
  -> Segment V2 n
  -> Segment V2 n
  -> Bool
segmentsEqual eps (Cubic a1 a2 a3) (Cubic b1 b2 b3)
  -- controlpoints equal within tol
  | distance a1 b1 < eps &&
    distance a2 b2 < eps &&
    distance a3 b3 < eps = True
  -- compare if both are colinear and close together
  -- | dist < eps                  &&
  --   colinear ((eps-dist)/2) cb1 &&
  --   colinear ((eps-dist)/2) cb2 = True
  | otherwise = False
  -- where dist = max (abs $ ld b0) (abs $ ld b3)
  --       ld   = distance lineDistance (Line a0 a3)
segmentsEqual _ _ _ = undefined

------------------------------------------------------------------------
-- Closing segments
------------------------------------------------------------------------

-- | A ClosingSegment is use to determine how to close a loop. A linear
--   closing means close a trail with a straight line. A cubic closing
--   segment means close the trail with a cubic bezier with control
--   points c1 and c2.
data ClosingSegment v n = LinearClosing | CubicClosing !(v n) !(v n)
  deriving Show

type instance V (ClosingSegment v n) = v
type instance N (ClosingSegment v n) = n

    -- Linear OffsetOpen             -> showString "openLinear"
    -- Cubic v1 v2 OffsetOpen        -> showParen (d > 10) $
    --   showString "openCubic " . showsPrec1 11 v1 . showChar ' '
    --                           . showsPrec1 11 v2

instance (Metric v, Foldable v, OrderedField n) => Transformable (ClosingSegment v n) where
  transform t (CubicClosing c1 c2) = CubicClosing (apply t c1) (apply t c2)
  transform _ LinearClosing        = LinearClosing
  {-# INLINE transform #-}

-- | Create a linear closing segment.
linearClosing :: ClosingSegment v n
linearClosing = LinearClosing
{-# INLINE linearClosing #-}

-- | Create a closing segment with control points @c1@ and @c2@.
cubicClosing :: v n -> v n -> ClosingSegment v n
cubicClosing = CubicClosing
{-# INLINE cubicClosing #-}

-- | Return the segment that closes a trail given the offset from the
--   start of the trail to the start of the closing segment.
closingSegment :: (Functor v, Num n) => v n -> ClosingSegment v n -> Segment v n
closingSegment off LinearClosing        = Linear (negated off)
closingSegment off (CubicClosing c1 c2) = Cubic c1 c2 (negated off)
{-# INLINE closingSegment #-}

------------------------------------------------------------------------
-- Fixed segments
------------------------------------------------------------------------

-- | @FixedSegment@s are like 'Segment's except that they have
--   absolute locations.  @FixedSegment v@ is isomorphic to @Located
--   (Segment Closed v)@, as witnessed by 'mkFixedSeg' and
--   'fromFixedSeg', but @FixedSegment@ is convenient when one needs
--   the absolute locations of the vertices and control points.
data FixedSegment v n
  = FLinear !(Point v n) !(Point v n)
  | FCubic  !(Point v n) !(Point v n) !(Point v n) !(Point v n)
  deriving (Show, Read, Eq)

type instance V (FixedSegment v n) = v
type instance N (FixedSegment v n) = n

instance Each (FixedSegment v n) (FixedSegment v' n') (Point v n) (Point v' n') where
  each f (FLinear p0 p1)      = FLinear <$> f p0 <*> f p1
  each f (FCubic p0 p1 p2 p3) = FCubic  <$> f p0 <*> f p1 <*> f p2 <*> f p3
  {-# INLINE each #-}

-- | Reverses the control points.
instance Reversing (FixedSegment v n) where
  reversing (FLinear p0 p1)      = FLinear p1 p0
  reversing (FCubic p0 p1 p2 p3) = FCubic p3 p2 p1 p0
  {-# INLINE reversing #-}

instance (Additive v, Foldable v, Num n) => Transformable (FixedSegment v n) where
  transform t = over each (transform t)
  {-# INLINE transform #-}

instance (Additive v, Num n) => HasOrigin (FixedSegment v n) where
  moveOriginTo o = over each (moveOriginTo o)
  {-# INLINE moveOriginTo #-}

instance (Metric v, OrderedField n) => Enveloped (FixedSegment v n) where
  getEnvelope f = moveTo p (getEnvelope s)
    where (p, s) = viewLoc $ f ^. fixed
  {-# INLINE getEnvelope #-}

instance (Metric v, OrderedField n)
      => HasArcLength (FixedSegment v n) where
  arcLengthBounded m s = arcLengthBounded m (s ^. fixed)
  arcLengthToParam m s = arcLengthToParam m (s ^. fixed)

instance (Metric v, OrderedField n) => HasSegments (FixedSegment v n) where
  segments = fixed . located
  {-# INLINE segments #-}
  offset = offset . view fixed
  {-# INLINE offset #-}

-- | Fixed segments and a located segments are isomorphic.
fixed :: (Additive v, Num n) => Iso' (FixedSegment v n) (Located (Segment v n))
fixed = iso fromFixedSeg mkFixedSeg
{-# INLINE fixed #-}

-- | Make a fixed segment from a located segment.
mkFixedSeg :: (Additive v, Num n) => Located (Segment v n) -> FixedSegment v n
mkFixedSeg = \case
  Loc p (Linear v)       -> FLinear p (p .+^ v)
  Loc p (Cubic c1 c2 x2) -> FCubic  p (p .+^ c1) (p .+^ c2) (p .+^ x2)
{-# INLINE mkFixedSeg #-}

-- | Make a located segment from a fixed one.
fromFixedSeg :: (Additive v, Num n) => FixedSegment v n -> Located (Segment v n)
fromFixedSeg = \case
  FLinear p1 p2      -> straight (p2 .-. p1) `at` p1
  FCubic x1 c1 c2 x2 -> bezier3 (c1 .-. x1) (c2 .-. x1) (x2 .-. x1) `at` x1
{-# INLINE fromFixedSeg #-}

type instance Codomain (FixedSegment v n) = Point v

instance (Additive v, Num n) => Parametric (FixedSegment v n) where
  atParam (FLinear p1 p2) t = lerp t p2 p1
  atParam (FCubic x1 c1 c2 x2) t = p3
    where p11 = lerp t c1 x1
          p12 = lerp t c2 c1
          p13 = lerp t x2 c2

          p21 = lerp t p12 p11
          p22 = lerp t p13 p12

          p3  = lerp t p22 p21
  {-# INLINE atParam #-}

instance Num n => DomainBounds (FixedSegment v n)

instance (Additive v, Num n) => EndValues (FixedSegment v n) where
  atStart (FLinear p0 _)     = p0
  atStart (FCubic  p0 _ _ _) = p0
  {-# INLINE atStart #-}
  atEnd   (FLinear _ p1)     = p1
  atEnd   (FCubic _ _ _ p1 ) = p1
  {-# INLINE atEnd #-}

instance (Additive v, Fractional n) => Sectionable (FixedSegment v n) where
  splitAtParam (FLinear p0 p1) t = (left, right)
    where left  = FLinear p0 p
          right = FLinear p  p1
          p = lerp t p1 p0
  splitAtParam (FCubic p0 c1 c2 p1) t = (left, right)
    where left  = FCubic p0 a b cut
          right = FCubic cut c d p1
          -- first round
          a   = lerp t c1 p0
          p   = lerp t c2 c1
          d   = lerp t p1 c2
          -- second round
          b   = lerp t p a
          c   = lerp t d p
          -- final round
          cut = lerp t c b
  {-# INLINE splitAtParam #-}

  reverseDomain (FLinear p0 p1)      = FLinear p1 p0
  reverseDomain (FCubic p0 p1 p2 p3) = FCubic p3 p2 p1 p0
  {-# INLINE reverseDomain #-}

closest :: FixedSegment v n -> Point v n -> [n]
closest = undefined

segmentPerametersAtDirection
  :: OrderedField n
  => V2 n
  -> Segment V2 n
  -> Node n
segmentPerametersAtDirection
  (V2 tx ty)
  (Cubic (V2 x1 y1) (V2 x2 y2) (V2 x3 y3)) =
  filterNode (\x -> x >= 0 && x <= 1) $ quadForm' a b c
    where
      a = tx*(y3 + 3*(y1 - y2)) - ty*(x3 + 3*(x1 - x2))
      b = 2*(tx*(y2 - 2*y1) - ty*(x2 - 2*x1))
      c = tx*y1 - ty*x1
segmentPerametersAtDirection _ _ = undefined

bezierPerametersAtDirection
  :: OrderedField n
  => V2 n
  -> FixedSegment V2 n
  -> Node n
bezierPerametersAtDirection
  (V2 tx ty)
  (FCubic (P (V2 x0 y0)) (P (V2 x1 y1)) (P (V2 x2 y2)) (P (V2 x3 y3))) =
  filterNode (\x -> x >= 0 && x <= 1) $ quadForm' a b c
    where
      a = tx*((y3 - y0) + 3*(y1 - y2)) - ty*((x3 - x0) + 3*(x1 - x2))
      b = 2*(tx*((y2 + y0) - 2*y1) - ty*((x2 + x0) - 2*x1))
      c = tx*(y1 - y0) - ty*(x1 - x0)
bezierPerametersAtDirection _ _ = undefined

