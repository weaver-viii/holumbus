module Main
(
   main
)
where


import Holumbus.MapReduce.Examples.SimpleDMapReduceIO 
import Holumbus.MapReduce.Examples.Sum
import System.Log

main :: IO ()
main = worker sumMap sumReduce [("Holumbus.MapReduce.Types",INFO),("measure",ERROR),("Holumbus.FileSystem",ERROR),("Holumbus.MapReduce",INFO),("Holumbus.Network",ERROR)]
