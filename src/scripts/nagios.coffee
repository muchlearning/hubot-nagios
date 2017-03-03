# Copyright 2015 Folker Bernitt
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

fs = require("fs");

room = process.env.HUBOT_NAGIOS_EVENT_NOTIFIER_ROOM
nagiosUrl = process.env.HUBOT_NAGIOS_URL
statusInterval = parseInt(process.env.HUBOT_NAGIOS_STATUS_INTERVAL || 600000)

module.exports = (robot) ->
  robot.brain.data.nagios_event_room = room

  topic = null
  set_topic = () ->
    fs.readFile "/var/cache/nagios3/status.dat", {encoding: "binary"}, (err, status) ->
      if err
        robot.logger.error err + ""
        return
      newtopic = calc_topic(status)
      if topic isnt newtopic
        topic = newtopic
        robot.logger.info "nagios: setting topic to #{topic}"
        robot.adapter.topic {room: event_room(robot)}, topic

  set_topic()
  setInterval set_topic, statusInterval

  robot.router.post '/hubot/nagios/host', (request, response) ->
    host = request.body.host
    hostOutput = request.body.hostoutput
    notificationType = request.body.notificationtype
    announceNagiosHostMessage host, hostOutput, notificationType, (msg) ->
      robot.messageRoom event_room(robot), msg

    set_topic()

    response.end ""

  robot.router.post '/hubot/nagios/service', (request, response) ->
    host = request.body.host
    serviceOutput = request.body.serviceoutput
    notificationType = request.body.notificationtype
    serviceDescription = request.body.servicedescription
    serviceState = request.body.servicestate

    announceNagiosServiceMessage host, notificationType, serviceDescription, serviceState, serviceOutput, (msg) ->
      robot.messageRoom event_room(robot), msg

    set_topic()

    response.end ""

event_room = (robot) ->
  return robot.brain.data.nagios_event_room

announceNagiosHostMessage = (host, hostOutput, notificationType, cb) ->
  cb "nagios #{notificationType}: #{host} is #{hostOutput}"

announceNagiosServiceMessage = (host, notificationType, serviceDescription, serviceState, serviceOutput, cb) ->
  cb "nagios #{notificationType}: #{host}:#{serviceDescription} is #{serviceState}: #{serviceOutput}"

hostsort = (a, b) ->
  if (a.last_hard_state > b.last_hard_state)
    -1
  else if (a.last_hard_state < b.last_hard_state)
    1
  else if (a.host_name < b.host_name)
    -1
  else if (a.host_name > b.host_name)
    1
  else
    0

servicesort = (a, b) ->
  hs = hostsort(a, b)
  if hs
    hs
  else if (a.service_description < b.service_description)
    -1
  else if (a.service_description > b.service_description)
    1
  else
    0

calc_topic = (status) ->
  hosts = [];
  services = [];
  curr = null;

  status = status.split("\n");

  for line in status
    if (/^\s*(\#.*)?$/.test(line))
      # ignore
    else if ((match = /\s*([a-zA-Z_]+)=(.*)/.exec(line)))
      if (curr)
        curr[match[1]] = match[2];
    else if (line is "hoststatus {")
      curr = {};
      hosts.push(curr);
    else if (line is "servicestatus {")
      curr = {};
      services.push(curr);
    else if (/^[a-zA-Z_]+ \{/.test(line))
      curr = null;

  is_bad = (stat) ->
    stat.scheduled_downtime_depth isnt "1" && (((stat.current_state is "1" || stat.current_state is "2") && (stat.last_hard_state is "1" || stat.last_hard_state is "2")) || stat.is_flapping is "1")

  hosts = hosts.filter(is_bad);

  hosts.sort hostsort

  services = services.filter(is_bad);

  services.sort servicesort

  counts = [0, 0, 0, 0, 0]

  hoststatus = (host) ->
    counts[host.last_hard_state]++
    if host.last_hard_state is "1" || host.last_hard_state is "2"
      stat = "#{host.host_name} #{host.plugin_output}"
      if host.is_flapping is "1"
        stat += " (FLAPPING)"
    else
      stat = "#{host.host_name} is FLAPPING"
    return stat

  servicestatus = (serv) ->
    counts[serv.last_hard_state]++
    if serv.last_hard_state is "1" || serv.last_hard_state is "2"
      stat = "#{serv.host_name}:#{serv.service_description} #{serv.plugin_output}"
      if serv.is_flapping is "1"
        stat += " (FLAPPING)"
    else
      stat = "#{serv.host_name}:#{serv.service_description} is FLAPPING"
    return stat

  host_str = (hoststatus host for host in hosts).join(" | ")
  service_str = (servicestatus service for service in services).join(" | ")

  summary = []
  if counts[2]
    summary.push(counts[2] + " CRITICAL")
  if counts[1]
    summary.push(counts[1] + " WARNING")
  if counts[0]
    summary.push(counts[0] + " FLAPPING")

  summary = summary.join(",")

  if host_str.length
    if service_str.length
      "#{summary}: #{host_str} | #{service_str}"
    else
      "#{summary}: #{host_str}"
  else
    if service_str.length
      "#{summary}: #{service_str}"
    else
      "All green"
