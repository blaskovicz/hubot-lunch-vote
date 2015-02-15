# Description:
#   Hold a vote for lunch; allows simultaneous votes in the same channel.
#
# Commands:
#   hubot lunchvote pending - show the pending lunch votes
#   hubot lunchvote create <time> - create a lunch vote for configuration
#   hubot lunchvote start <id> - start the voting phase for #id
#   hubot lunchvote cancel <id> - cancel the vote #id
#   hubot lunchvote status <id> - return info about vote #id
#   hubot lunchvote end <id> - end vote #id early
#   hubot lunchvote add <option> to <id>  - add an option for vote #id
#   hubot lunchvote for <option> in <id> - cast a vote on the open #id for the given option
#
# Examples:
#   hubot lunchvote create 15
#   hubot lunchvote add valencia to 5
#   hubot lunchvote add mcdonalds to 5
#   hubot lunchvote start 5
#   hubot lunchvote for mcdonalds in 5
#   hubot lunchvote end 5
#   hubot lunchvote cancel 5

module.exports = (robot) ->
  robot.respond /lunchvote pending$/i, (msg) ->
    msgString = "the pending lunchvotes are"
    room = robot.brain.userForId 'broadcast'
    room.room = msg.message.user.room
    room.type = 'groupchat'
    robot.send room, msgString

  robot.respond /lunchvote create\s?(.*)?$/i, (msg) ->
    vote = new LunchVote(msg.message.user.name)
    vote.room = robot.brain.userForId 'broadcast'
    vote.room.room = msg.message.user.room
    vote.room.type = 'groupchat'
    vote.saveToBrain(robot)
    msg.reply "Created lunch vote #{vote.id} with owner #{msg.message.user.name}"

  robot.respond /lunchvote status\s(.+)$/i, (msg) ->
    id = msg.match[1].trim()
    vote = LunchVote.fromBrain id, robot
    try
      msg.reply vote.toString()
    catch e
      robot.logger.error e

  robot.respond /lunchvote start\s(.+)$/i, (msg) ->
    id = msg.match[1].trim()
    vote = LunchVote.fromBrain id, robot
    if not vote?
      msg.reply "Could not find lunch vote #{id}"
    else if msg.message.user.name isnt vote.owner
      msg.reply "Only the owner of this vote, #{vote.owner}, can start it"
    else if vote.status isnt LunchVoteStatus.config
      msg.reply "Lunch votes cannot be started if they have alread run"
    else if vote.choices.length < 2
      msg.reply "Lunch votes must have more than one choice before they can be run"
    else
      #TODO actually start a timer here
      #TODO handle the creation room vs the starting room
      vote.status = LunchVoteStatus.pending
      vote.saveToBrain robot
      msg.reply "Lunch vote #{vote.id} can now be voted on"

  robot.respond /lunchvote cancel\s(.+)$/i, (msg) ->
    #TODO don't require id if there is only one vote in a channel
    #TODO create a findByChannel function
    #TODO verify all votes are going on in a channel
    #TODO send only messages to a single channel
    id = msg.match[1].trim()
    vote = LunchVote.fromBrain id, robot
    if not vote?
      msg.reply "Could not find lunch vote #{id}"
    else if vote.status is LunchVoteStatus.complete or vote.status is LunchVoteStatus.cancelled
      msg.reply "Only open lunch votes can be cancelled"
    else if msg.message.user.name isnt vote.owner
      msg.reply "Only the owner of this vote, #{vote.owner}, can cancel it"
    else
      vote.status = LunchVoteStatus.cancelled
      vote.saveToBrain robot
      msg.reply "Lunch vote #{id} cancelled"

  robot.respond /lunchvote end\s(.+)$/i, (msg) ->
    id = msg.match[1].trim()
    vote = LunchVote.fromBrain id, robot
    if not vote?
      msg.reply "Could not find lunch vote #{id}"
    else if vote.status isnt LunchVoteStatus.pending or not vote.canDrawWinner()
      msg.reply "Only pending lunch votes with at least 2 votes can be ended; if the vote hasn't started yet it can be cancelled"
    else if msg.message.user.name isnt vote.owner
      msg.reply "Only the owner of this vote, #{vote.owner}, can end it"
    else
      vote.status = LunchVoteStatus.complete
      vote.drawWinner()
      vote.saveToBrain robot
      msg.reply vote.winnerString()

  robot.respond /lunchvote add\s+(.+)\s+to\s+(.+)/i, (msg) ->
    choice = msg.match[1]
    id = msg.match[2].trim()
    vote = LunchVote.fromBrain id, robot
    if not vote?
      msg.reply "Could not find lunch vote #{id}"
    else if vote.status isnt LunchVoteStatus.config
      msg.reply "Lunch must still be in the config state to add choices"
    else if vote.containsChoice choice
      msg.reply "Lunch vote already contains choice"
    else
      vote.addChoice choice
      vote.saveToBrain robot
      msg.reply "Choice '#{choice}' successfully added to lunch vote vote #{id}"

  robot.respond /lunchvote for\s+(.+)\s+in\s+(.+)/i, (msg) ->
    choice = msg.match[1]
    id = msg.match[2].trim()
    vote = LunchVote.fromBrain id, robot
    if not vote?
      msg.reply "Could not find lunch vote #{id}"
    else if vote.status isnt LunchVoteStatus.pending
      msg.reply "Lunch votes must be started before they are eligible for ballots"
    else if not vote.containsChoice choice
      msg.reply "Choice invalid for lunchvote"
    else if vote.hasVoted msg.message.user.name
      msg.reply "You have already cast a ballot for this vote"
    else
      ballot = new LunchBallot msg.message.user.name, choice
      vote.castBallot ballot
      vote.saveToBrain robot
      msg.reply "Ballot successfully cast for '#{choice}' in vote #{id}"

UUID = require 'node-uuid'
brainPrefix = "lunchvote"
LunchVoteStatus =
  config: 0
  complete: 1
  cancelled: 2
  pending: 3

class LunchVoteFilterResult
  constructor: (@result, @msg) ->
    throw "result must be a boolean" unless @result? and \
      (@result instanceof Boolean or @result instanceof boolean)
class LunchVoteFilter
  constructor: (@id, @robot, @msg, @choice) ->
    throw "id, robot and msg must be provided" \
      unless @id? and @robot? and @msg? and @choice?
  trueResult: (msg) ->
    new LunchVoteFilterResult true, msg
  falseResult: (msg) ->
    new LunchVoteFilterResult false, msg
  meetCriteria: ->
    new LunchVoteFilterResult true
class LunchVoteOwner extends LunchVoteFilter
  meetCriteria: ->
    vote = LunchVote.fromBrain @id, @robot
    if vote? and vote.owner is msg.message.user.name
      @trueResult()
    else
      @falseResult "only the owner of a lunch vote can do that"

class LunchBallot
  constructor: (@voter, choice) ->
    throw "voter must be passed" unless @voter?
    throw "choice must be passed" unless choice?
    @choice = choice.toLowerCase()
class LunchVote
  ourPrefix = "#{brainPrefix}:vote"
  constructor: (@owner, @time = 600) ->
    @id = UUID.v4()
    @room = null
    @status = LunchVoteStatus.config
    @choices = []
    @ballots = []
  @fromBrain: (id, robot) ->
    vote = new LunchVote()
    voteString = robot.brain.get "#{ourPrefix}:#{id}"
    return null unless voteString? and voteString != ""
    voteJSON = JSON.parse voteString
    for propName in ["status", "ballots", "choices", "id", "owner", "time", "room"]
      vote[propName] = voteJSON[propName]
    vote
  canDrawWinner: ->
    @choices.length > 1 and @ballots.length > 1 and not @winner?
  drawWinner: ->
    return unless @canDrawWinner()
    tally = @voteTally()
    maxVoteCount = 0
    maxVoteCount = count for choice,count of tally when count > maxVoteCount
    contestants = (choice for choice,count of tally when count is maxVoteCount)
    @winner = if contestants.length is 1 then contestants[0] else contestants[Math.floor(Math.random() * contestants.length)]
    @tieBroken = contestants.length isnt 1
  voteTally: ->
    tally = {}
    for vote in @ballots
      tally[vote.choice] ?= 0
      tally[vote.choice]++
    tally
  winnerString: ->
    return "Voting isn't complete" unless @winner?
    string = "Vote #{@id} winner: '#{@winner}'#{if @tieBroken then ' (tie winner)' else ''}"
    for choice, count of @voteTally()
      string += "; #{choice}: #{count}"
    string
  hasVoted: (username) ->
    found = ballot for ballot in @ballots when ballot.voter is username
    found?
  castBallot: (ballot) ->
    return if not ballot? or @hasVoted(ballot.voter)
    throw "invalid choice" unless @containsChoice(ballot.choice)
    @ballots.push ballot
  addChoice: (choice) ->
    choice = choice.toLowerCase() if choice?
    return if @containsChoice(choice)
    @choices.push choice
  containsChoice: (choice) ->
    choice = choice.toLowerCase() if choice?
    found = choice for existingChoice in @choices when choice is existingChoice
    found?
  statusString: ->
    key for key,value of LunchVoteStatus when @status is value
  toString: ->
    choiceStr = @choices.join(", ")
    voteTemp = []
    for ballot in @ballots
      voteTemp.push "#{ballot.voter} -> #{ballot.choice}, "
    "[LunchVote id: #{@id}, owner: #{@owner}, status: #{@statusString()} (#{@status}), time: #{@time}, room: #{@room.room}, choices: (#{choiceStr}), votes: (#{voteTemp.join(', ')})]"
  saveToBrain: (robot) ->
    throw "owner required for save" unless @owner?
    robot.brain.set "#{ourPrefix}:#{@id}", JSON.stringify @
  getPending: (robot) ->


