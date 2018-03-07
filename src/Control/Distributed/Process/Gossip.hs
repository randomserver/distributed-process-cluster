{-# LANGUAGE DeriveGeneric
            , LambdaCase
            , ImplicitParams  #-}
module Control.Distributed.Process.Gossip(runCluster) where

import Data.Binary (Binary)
import GHC.Generics
import System.Random
import Data.List
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad.Reader
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Node
import Control.Distributed.Process.Gossip.Internal.VClock as VClock

type Version = VClock ProcessId Integer

data Protocol = Join ProcessId
              | JoinAck ProcessId Version [ProcessId]
              | Gossip ProcessId Version [ProcessId]
              | GossipTimer
              deriving(Show, Eq, Generic)

instance Binary Protocol where

data ClusterState  = ClusterState {
    _version :: Version,
    _peers :: [ProcessId]
}

data Config = Config { state :: !(TVar ClusterState) }

put :: (MonadIO m) => (?config :: Config) => ClusterState -> m ClusterState
put cs = liftIO $ atomically $ swapTVar (state ?config) cs

get :: (MonadIO m) => (?config :: Config) => m ClusterState
get = liftIO $ readTVarIO (state ?config)

modify :: (MonadIO m) => (?config :: Config) => (ClusterState -> ClusterState) -> m ()
modify f = liftIO $ atomically $ modifyTVar' (state ?config) f

timer t p = spawnLocal $ forever (liftIO $ threadDelay t) >> p

sample :: [g] -> IO g
sample lst = do
    i <- randomRIO (0, length lst -1)
    return $ lst !! i

dogossip :: (?config :: Config) => Process ()
dogossip = do
    self <- getSelfPid
    ClusterState version peers <- get
    p <- liftIO $ sample peers
    send p (Gossip self version peers)

handlegossip :: (?config :: Config) => ProcessId -> Version -> [ProcessId] -> Process ()
handlegossip pid v1 peers = do
    say $ "Gossip from " ++ (show pid)
    ClusterState v2 peers2 <- get
    put $ case v1 `relates` v2 of
        Same -> ClusterState v1 peers
        Before -> ClusterState v2 peers2
        After -> ClusterState v1 peers
        Concurrent -> ClusterState (v1 `merge` v2) (peers `union` peers2)

    ClusterState _ npeers <- get
    say $ "Now have" ++ (show npeers)
    return ()


initialized  :: (?config :: Config) => Process ()
initialized = do
    pid <- getSelfPid
    say $ "Cluster started"
    spawnLocal $ forever $ do
        liftIO $ threadDelay 5000000
        send pid GossipTimer

    forever $ expect >>= \case
        Join id     -> do
            say $ (show id) ++ "Wants to join"
            modify $ \s -> s { _version = VClock.inc pid (_version s),
                               _peers = id : (_peers s) }
            ClusterState v p <- get
            send id (JoinAck id v p)
        GossipTimer -> dogossip
        Gossip id version peers -> handlegossip id version peers
        _           -> say $ "Got something else"

uninitialized :: (?config :: Config) => [NodeId] -> Process ()
uninitialized [] = do
    pid <- getSelfPid

    modify $ \s -> s { _version = VClock.incDefault pid 0 (_version s),
                       _peers = [pid] }
    initialized

uninitialized seeds = do
    pid <- getSelfPid
    seedNode <- liftIO $ sample seeds

    say $ "Trying to join " ++ show seedNode
    nsendRemote seedNode "Cluster:Controller" (Join pid)
    receiveWait [match $ joining]

joining (JoinAck rpid version peers) = do
    pid <- getSelfPid

    modify $ \s -> s { _version = VClock.incDefault pid 0 version, 
                       _peers = peers }

    say $ "Joined"
    initialized

runCluster :: LocalNode -> [NodeId] -> Process () -> IO ()
runCluster node seeds proc = do
    cstate <- newTVarIO initialState
    let ?config = Config cstate
    _ <- forkProcess node $ do
        getSelfPid >>= register "Cluster:Controller"
        uninitialized seeds
    runProcess node proc
    where initialState = ClusterState VClock.empty [] 
    