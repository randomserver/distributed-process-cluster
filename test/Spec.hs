import Test.Framework
import Test.Framework.Providers.HUnit
import Test.HUnit
import Control.Distributed.Process.Gossip.Internal.VClock as VC

main :: IO ()
main = defaultMain [ testCase "insert" test_insert
                   , testCase "lookup" test_lookup
                   , testCase "merge" test_merge
                   , testCase "inc" test_inc
                   , testCase "incDefault" test_incDefault
                   , testCase "relate_before 1" test_relate_before1
                   , testCase "relate_before 2" test_relate_before2
                   , testCase "relate_before 3" test_relate_before3
                   , testCase "relate_concurrent 1" test_relate_concurrent1
                   , testCase "relate_concurrent 2" test_relate_concurrent2]


test_insert :: Assertion
test_insert = do
    insert ("0", 1) c @?= fromList [("0", 1), ("a", 2)]
    insert ("a", 1) c @?= fromList [("a", 2)]
    insert ("a", 3) c @?= fromList [("a", 3)]
        where c = fromList [("a", 2)]

test_lookup = do
    VC.lookup "a" c @?= Just 1
    VC.lookup "a" (empty :: VClock String Int) @?= Nothing
        where c = insert ("a", 1) empty

test_merge = VC.merge c1 c2 @?= merged
    where c1 = fromList [("a", 1), ("b", 1)]
          c2 = fromList [("a", 1), ("b", 2), ("c", 3)]
          merged = fromList [("a", 1), ("b", 2), ("c", 3)]

test_inc = do
    VC.inc "a" c @?= fromList [("a", 2)]
    VC.inc "b" c @?= fromList [("a", 1)]
        where c = fromList [("a", 1)]


test_incDefault = do
    VC.incDefault "a" 0 c @?= fromList [("a", 2)]
    VC.incDefault "b" 2 c @?= fromList [("a", 1), ("b", 2)]
    VC.incDefault "0" 2 c @?= fromList [("0", 2), ("a", 1)]
        where c = fromList [("a", 1)]

test_relate_before1 = let c1 = insert ("a", 0) empty 
                          c2 = inc "a" c1
                       in c1 `relates` c2 @?= Before

test_relate_before2 = let clock1_1 = empty :: VClock String Int
                          clock2_1 = incDefault "1" 0 clock1_1
                          clock3_1 = incDefault "2" 0 clock2_1
                          clock4_1 = incDefault "1" 0 clock3_1
                          clock1_2 = empty :: VClock String Int
                          clock2_2 = incDefault "1" 0 clock1_2
                          clock3_2 = incDefault "2" 0 clock2_2
                          clock4_2 = incDefault "1" 0 clock3_2
                          clock5_2 = incDefault "3" 0 clock4_2
                       in clock4_1 `relates` clock5_2 @?= Before

test_relate_before3 = let clock1_1 = empty :: VClock String Int
                          clock2_1 = incDefault "2" 0 clock1_1
                          clock3_1 = incDefault "2" 0 clock2_1
                          clock1_2 = empty :: VClock String Int
                          clock2_2 = incDefault "1" 0 clock1_2
                          clock3_2 = incDefault "2" 0 clock2_2
                          clock4_2 = incDefault "2" 0 clock3_2
                          clock5_2 = incDefault "3" 0 clock4_2
                        in do
                            clock3_1 `relates` clock5_2 @?= Before
                            clock5_2 `relates` clock3_1 @?= After
                      
test_relate_concurrent1 = let clock1_1 = empty :: VClock String Int
                              clock2_1 = incDefault "1" 0 clock1_1
                              clock1_2 = empty :: VClock String Int
                              clock2_2 = incDefault "2" 0 clock1_2
                           in clock2_1 `relates` clock2_2 @?= Concurrent


test_relate_concurrent2 = let clock1 = fromList [("1", 0), ("2", 1), ("3", 0)]
                              clock2 = fromList [("1", 0), ("2", 3)]
                           in do
                               clock1 `relates` clock2 @?= Concurrent
                               clock2 `relates` clock1 @?= Concurrent
