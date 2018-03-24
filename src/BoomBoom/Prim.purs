module BoomBoom.Prim where

import Prelude

import Control.Alt (class Alt, (<|>))
import Data.Maybe (Maybe(..))
import Data.Monoid (class Monoid, mempty)
import Data.Newtype (class Newtype)
import Data.Record (get, insert)
import Data.Variant (Variant, case_, inj, on)
import Type.Prelude (class IsSymbol, class RowLacks, SProxy)

-- | Our core type - nearly an iso:
-- | `{ ser: a → tok, prs: tok → Maybe a }`
newtype BoomBoom tok a = BoomBoom (BoomBoomD tok tok a a)
derive instance newtypeBoomBoom ∷ Newtype (BoomBoom tok a) _

-- | __D__ from diverging as `a'` can diverge from `a`
-- | and `tok'` can diverge from tok
newtype BoomBoomD tok' tok a' a = BoomBoomD
  { prs ∷ tok → Maybe { a ∷ a, tok ∷ tok }
  , ser ∷ a' → tok'
  }
derive instance newtypeBoomBoomD ∷ Newtype (BoomBoomD tok' tok a' a) _
derive instance functorBoomBoomD ∷ Functor (BoomBoomD tok' tok a')

-- | `divergeA` together with `BoomBoomD` `Applicative`
-- | instance form quite nice API to create by hand
-- | `BoomBooms` for records (or other product types):
-- |
-- | recordB ∷ BoomBoom String {x :: Int, y :: Int}
-- | recordB = BoomBoom $
-- |   {x: _, y: _}
-- |   <$> _.x >- int
-- |   <* lit "/"
-- |   <*> _.y >- int
-- |
-- | This manual work is tedious and can
-- | lead to incoherency in final `BoomBoom`
-- | - serializer can produce something which
-- | is not parsable or the other way around.
-- | Probably there are case where you want
-- | it so here it is.
-- |
divergeA ∷ ∀ a a' tok. (a' → a) → BoomBoom tok a → BoomBoomD tok tok a' a
divergeA d (BoomBoom (BoomBoomD { prs, ser })) = BoomBoomD { prs, ser: d >>> ser }

infixl 5 divergeA as >-

instance applyBoomBoomD ∷ (Semigroup tok) ⇒ Apply (BoomBoomD tok tok a') where
  apply (BoomBoomD b1) (BoomBoomD b2) = BoomBoomD { prs, ser }
    where
    prs t = do
      { a: f, tok: t' } ← b1.prs t
      { a, tok: t'' } ← b2.prs t'
      pure { a: f a, tok: t'' }
    ser = (<>) <$> b1.ser <*> b2.ser

instance applicativeBoomBoomD ∷ (Monoid tok) ⇒ Applicative (BoomBoomD tok tok a') where
  pure a = BoomBoomD { prs: pure <<< const { a, tok: mempty }, ser: const mempty }

-- | This `Alt` instance is also somewhat dangerous - it allows
-- | you to define inconsistent `BoomBoom` in case for example
-- | of your sum type so you can get `tok's` `mempty` as a result
-- | of serialization which is not parsable.
instance altBoomBoom ∷ (Monoid tok) ⇒ Alt (BoomBoomD tok tok a') where
  alt (BoomBoomD b1) (BoomBoomD b2) = BoomBoomD { prs, ser }
    where
    -- | Piece of premature optimization ;-)
    prs tok = case b1.prs tok of
      Nothing → b2.prs tok
      r → r
    ser = (<>) <$> b1.ser <*> b2.ser

-- | Enter the world of two categories which fully keep track of
-- | `BoomBoom` divergence and allow us define constructors
-- | for secure record and variant `BoomBooms`.
newtype BoomBoomPrsAFn tok a r r' = BoomBoomPrsAFn (BoomBoomD tok tok a (r → r'))

instance semigroupoidBoomBoomPrsAFn ∷ (Semigroup tok) ⇒ Semigroupoid (BoomBoomPrsAFn tok a) where
  compose (BoomBoomPrsAFn (BoomBoomD b1)) (BoomBoomPrsAFn (BoomBoomD b2)) = BoomBoomPrsAFn $ BoomBoomD $
    { prs: \tok → do
        {a: r, tok: tok'} ← b2.prs tok
        {a: r', tok: tok''} ← b1.prs tok'
        pure {a: r' <<< r, tok: tok''}
    , ser: (<>) <$> b1.ser <*> b2.ser
    }

instance categoryBoomBoomPrsAFn ∷ (Monoid tok) ⇒ Category (BoomBoomPrsAFn tok a) where
  id = BoomBoomPrsAFn $ BoomBoomD $
    { prs: \tok → pure { a: id, tok }
    , ser: const mempty
    }

newtype BoomBoomSerTokFn tok a r r' = BoomBoomSerTokFn (BoomBoomD ((r' → tok) → tok) tok r a)

instance semigroupoidBoomBoomSerTokFn ∷ (Semigroup tok) ⇒ Semigroupoid (BoomBoomSerTokFn tok a) where
  compose (BoomBoomSerTokFn (BoomBoomD b1)) (BoomBoomSerTokFn (BoomBoomD b2)) = BoomBoomSerTokFn $ BoomBoomD $
    { prs: \tok → b1.prs tok <|> b2.prs tok
    , ser: \a c2t →
        b2.ser a \b →
          b1.ser b \c →
            c2t c
    }

addChoice
  ∷ forall t561 t578 t579 a r r' s s' n tok x y
  . RowCons n a r r'
  ⇒ RowCons n a s s'
  ⇒ IsSymbol n
  ⇒ Semigroup tok
  ⇒ SProxy n
  → (SProxy n → BoomBoomSerTokFn tok (Variant s') (Variant r') (Variant r'))
  → BoomBoom tok a
  → BoomBoomSerTokFn tok (Variant s') (Variant r') (Variant r)
addChoice p lit (BoomBoom (BoomBoomD b)) = lit p >>> choice
  where
  choice = BoomBoomSerTokFn $ BoomBoomD $
    { prs: b.prs >=> \{a, tok} → pure { a: inj p a, tok }
    , ser: \v c →
        (on p b.ser c) v
    }

buildVariant
  ∷ ∀ a tok
  . BoomBoomSerTokFn tok a a (Variant ())
  → BoomBoom tok a
buildVariant (BoomBoomSerTokFn (BoomBoomD {prs, ser})) = BoomBoom $ BoomBoomD $
  { prs
  , ser: \v → ser v case_
  }

addField ∷ ∀ a n r r' s s' tok
  . RowCons n a s s'
  ⇒ RowLacks n s
  ⇒ RowCons n a r r'
  ⇒ RowLacks n r
  ⇒ IsSymbol n
  ⇒ SProxy n
  → BoomBoom tok a
  → BoomBoomPrsAFn tok { | s'} { | r } { | r'}
addField p (BoomBoom (BoomBoomD b)) = BoomBoomPrsAFn $ BoomBoomD $
  { prs: \t → b.prs t <#> \{a, tok} →
      { a: \r → insert p a r, tok }
  , ser: \r → b.ser (get p r)
  }

buildRecord
  ∷ ∀ r tok
  . BoomBoomPrsAFn tok r {} r
  → BoomBoom tok r
buildRecord (BoomBoomPrsAFn (BoomBoomD b)) = BoomBoom $ BoomBoomD
  { prs: \tok → do
      {a: r2r, tok: tok'} ← b.prs tok
      pure {a: r2r {}, tok: tok'}
  , ser: b.ser
  }

