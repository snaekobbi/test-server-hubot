# Description
#   hubot scripts for managing Pipeline 2
#
# Commands:
#   hubot pipeline server load - Reply back with the server load
#   hubot pipeline get URL - Reply back with the response from the given Web API path
#
# Author:
#   Jostein Austvik Jacobsen <josteinaj@gmail.com>

child_process = require 'child_process'

module.exports = (robot) ->
  
  robot.respond /pipeline server ?load/i, (msg) ->
    msg.send "Checking Pipeline 2 server load..."
    load = getLoad msg, (load) ->
      msg.send "Pipeline 2 engine CPU: "+load.engine.cpu+" %"
      msg.send "Pipeline 2 engine memory: "+load.engine.mem+" %"
      msg.send "Pipeline 2 engine latency: "+load.engine.latency+" s"
      msg.send "Pipeline 2 web ui CPU: "+load.webui.cpu+" %"
      msg.send "Pipeline 2 web ui memory: "+load.webui.mem+" %"
      msg.send "Pipeline 2 web ui latency: "+load.webui.latency+" s"

  robot.respond /pipeline get (.*)/i, (msg) ->
    url = "http://localhost:8181/ws"+msg.match[1]
    msg.send "GETing "+url+"..."
    robot.http(url).get() (err, res, body) ->
      if err
        msg.send "Error: "+err
      else
        msg.send "Response code: "+res.statusCode
        msg.send "body: [\n"+body+"\n]"
  
  getLoad = (msg, callback) ->
    child_process.exec "nproc", (error, stdout, stderr) ->
      nproc = +stdout.split('\n')[0] # number or processors/cores. If there's 4 cores; the max cpu will be 400%
      child_process.exec "ps aux | grep -v grep | grep daisy | grep felix.jar | awk '{print $2}'", (error, stdout, stderr) ->
        enginePid = stdout.split('\n')[0]
        child_process.exec "ps aux | grep -v grep | grep daisy | grep java | grep webui | awk '{print $2}'", (error, stdout, stderr) ->
          webuiPid = stdout.split('\n')[0]
          command = "top -b -n 1 -p "
          numberOfProcs = 0
          if enginePid.length != 0 and webuiPid.length == 0
            command += enginePid
            numberOfProcs = 1
          else if enginePid.length == 0 and webuiPid.length != 0
            command += webuiPid
            numberOfProcs = 1
          else if enginePid.length != 0 and webuiPid.length != 0
            command += enginePid+","+webuiPid
            numberOfProcs = 2
          else
            callback {
              engine: {
                "cpu": -1,
                "mem": -1,
                "latency": -1
              },
              webui: {
                "cpu": -1,
                "mem": -1,
                "latency": -1
              }
            }
          command += " | grep . | tail -n "+numberOfProcs+" | awk '{print $1 \" \" $9 \" \" $10}'"
          child_process.exec command, (error, stdout, stderr) ->
            engineCpu = -1
            webuiCpu = -1
            engineMem = -1
            webuiMem = -1
            for proc in stdout.split('\n')
              split = proc.split(' ')
              if split[0] == enginePid
                engineCpu = +split[1] / nproc
                engineMem = +split[2]
              else if split[0] == webuiPid
                webuiCpu = +split[1] / nproc
                webuiMem = +split[2]
            child_process.exec 'curl -s -o /dev/null --max-time 30 -w "%{http_code};%{time_total}\n" localhost:8181/ws/jobs | grep ";"', (error, stdout, stderr) ->
              engineLatency = "unreachable"
              if stdout.split('\n')[0].split(";")[0] == "200"
                engineLatency = +(stdout.split('\n')[0].split(";")[1].replace(/,/,"."))
              child_process.exec 'curl -s -o /dev/null --max-time 30 -w "%{http_code};%{time_total}\n" localhost:9000/alive | grep ";"', (error, stdout, stderr) ->
                webuiLatency = "unreachable"
                if stdout.split('\n')[0].split(";")[0] == "200"
                  webuiLatency = +(stdout.split('\n')[0].split(";")[1].replace(/,/,"."))
                callback {
                  engine: {
                    "cpu": engineCpu,
                    "mem": engineMem,
                    "latency": engineLatency
                  },
                  webui: {
                    "cpu": webuiCpu,
                    "mem": webuiMem,
                    "latency": webuiLatency
                  }
                }
  
    # could run scripts with something like this probably:
    # build = spawn '/bin/bash', ['test.sh']
  
  # this starts a new load monitor every 5 minutes
  setInterval () ->
    killIfOnAverageAbove 300
  , 300000
  
  # this checks the latency every 2 minutes
  setInterval () ->
    if not(typeof load.engine.latency is 'number') or load.engine.latency > 30.0
      robot.adapter.send {room:'server'}, "Pipeline 2 Engine is unreachable (latency="+load.engine.latency+"); restarting the Engine..."
      child_process.exec "NO_MESSAGES=1 ./pipeline-stop engine ; NO_MESSAGES=1 ./pipeline-start engine", { cwd: process.env.HOME+"/hubot/bash/handlers/" }, (error, stdout, stderr) ->
        robot.adapter.send {room:'server'}, "System restart complete."
    if not(typeof load.webui.latency is 'number') or load.webui.latency > 30.0
      robot.adapter.send {room:'server'}, "Pipeline 2 Web UI is unreachable (latency="+load.webui.latency+"); restarting the Web UI..."
      child_process.exec "NO_MESSAGES=1 ./pipeline-stop webui ; NO_MESSAGES=1 ./pipeline-start webui", { cwd: process.env.HOME+"/hubot/bash/handlers/" }, (error, stdout, stderr) ->
        robot.adapter.send {room:'server'}, "System restart complete."
  , 180000

  killIfOnAverageAbove = (timeRemaining, timeRunning = 0, average = 0, iterations = 0) ->
    getLoad "", (load) ->
      average = ( average * iterations + load.engine.cpu ) / ( iterations + 1 )
      if timeRemaining <= 0
        if average > 70
          robot.adapter.send {room:'server'}, "NOTE: Average CPU load for the last 5 minutes is "+average+" %"
          #robot.adapter.send {room:'server'}, "CPU load has been on average above 70% for the last 5 minutes, Pipeline 2 has most likely crashed"
          #robot.adapter.send {room:'server'}, "I will try to restart Pipeline 2 now to fix this..."
          #child_process.exec "NO_MESSAGES=1 ./pipeline-stop ; NO_MESSAGES=1 ./pipeline-start", { cwd: process.env.HOME+"/hubot/bash/handlers/" }, (error, stdout, stderr) ->
          #  robot.adapter.send {room:'server'}, "Ok, I'm done. Let's hope things run more smoothly from now on."
      else
        setTimeout () ->
          killIfOnAverageAbove timeRemaining - 1, timeRunning + 1, average, iterations + 1
        , 1000
