{-# LANGUAGE DeriveGeneric
            , LambdaCase
            , ImplicitParams  #-}
module Control.Distributed.Process.Gossip(runCluster, getpeers) where

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

data Peer = Peer ProcessId PeerState
    deriving (Show, Generic)

data GetPeers = GetPeers
    deriving (Show, Generic)

data Protocol = Join ProcessId
              | JoinAck ProcessId Version [Peer]
              | Gossip ProcessId Version [Peer]
              | GossipTimer
              | Ping ProcessId | Pong
              deriving(Show, Eq, Generic)


data PeerState = Up | Down deriving (Show, Eq, Generic)

instance Binary Protocol where
instance Binary PeerState where
instance Binary Peer where
instance Binary GetPeers

instance Eq Peer where
    (Peer p1 _) == (Peer p2 _) = p1 == p2

data ClusterState  = ClusterState {
    _version :: Version,
    _peers :: [Peer]
}

data Config = Config { state :: !(TVar ClusterState) }

put :: (MonadIO m) => (?config :: Config) => ClusterState -> m ClusterState
put cs = liftIO $ atomically $ swapTVar (state ?config) cs

get :: (MonadIO m) => (?config :: Config) => m ClusterState
get = liftIO $ readTVarIO (state ?config)

modify :: (MonadIO m) => (?config :: Config) => (ClusterState -> ClusterState) -> m ()
modify f = liftIO $ atomically $ modifyTVar' (state ?config) f

sample :: [g] -> IO g
sample lst = do
    i <- randomRIO (0, length lst -1)
    return $ lst !! i

handle GossipTimer = do
    self <- getSelfPid
    ClusterState version peers <- get
    Peer p _ <- liftIO $ sample (filter (\(Peer p s) -> s == Up) peers)
    send p (Gossip self version peers)

handle (Gossip pid v1 peers) = do
    ClusterState v2 peers2 <- get
    put $ case v1 `relates` v2 of
        Same -> ClusterState v1 peers
        Before -> ClusterState v2 peers2
        After -> ClusterState v1 peers
        Concurrent -> ClusterState (v1 `merge` v2) (peers `union` peers2)

    ClusterState _ npeers <- get
    return ()

handle (Join id) = do
    self <- getSelfPid
    modify $ \s -> s { _version = VClock.inc self (_version s),
                       _peers = [Peer id Up] `union` (_peers s) }
    ClusterState v p <- get
    send id (JoinAck self v p)
    return ()

handle (Ping p) = do
    send p Pong

handlePeerRequest :: (?config :: Config) => SendPort [ProcessId] -> Process ()
handlePeerRequest sender = do
    ClusterState _ npeers <- get
    sendChan sender $  map (\(Peer p _) -> p) $ filter (\(Peer _ s) -> s == Up) npeers

getpeers :: Process [NodeId]
getpeers = do
    (sp, rp) <- newChan
    nsend clusterController (sp :: SendPort [ProcessId])
    receiveChan rp >>= return . map processNodeId


heartbeat :: (?config :: Config) => Process ()
heartbeat = forever $ do
    self <- getSelfPid
    liftIO $ threadDelay 5000000
    ClusterState _ peers <- get
    Peer p _ <- liftIO $ sample (filter (\(Peer p s) -> s == Up) peers)
    send p (Ping self)
    expectTimeout 1000000 >>= \case
        (Just Pong) -> return ()
        Nothing     -> modify $ \s -> s { _version = VClock.inc self (_version s),
                                          _peers = [Peer p Down] `union` (_peers s)}


clusterController = "Cluster:Controller"

gossip :: (?config :: Config) => ProcessId -> Process ()
gossip pid = do
    forever $ do
        liftIO $ threadDelay 5000000
        send pid GossipTimer


initialized  :: (?config :: Config) => Process ()
initialized = do
    pid <- getSelfPid
    say $ "Cluster started"

    spawnLocal $ gossip pid
    spawnLocal heartbeat

    forever $ receiveWait [ match handle,
                            match handlePeerRequest ]

uninitialized :: (?config :: Config) => [NodeId] -> Process ()
uninitialized [] = do
    pid <- getSelfPid

    modify $ \s -> s { _version = VClock.incDefault pid 0 (_version s),
                       _peers = [Peer pid Up] }
    initialized

uninitialized seeds = do
    pid <- getSelfPid
    seedNode <- liftIO $ sample seeds

    say $ "Trying to join " ++ show seedNode
    nsendRemote seedNode clusterController (Join pid)
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
        getSelfPid >>= register clusterController
        uninitialized seeds
    runProcess node proc
    where initialState = ClusterState VClock.empty [] 
    