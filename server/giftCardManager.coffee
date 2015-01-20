ObjectId                      = require('mongodb').ObjectID
mongoManager                  = require '../managers/mongoManager'
baseModel                     = require '../managers/baseModel'
baseManager                   = require '../managers/baseManager2'
locationManager               = require '../managers/locationManager'
cronManager                   = require '../managers/cronManager'
giftCardTransactionManager    = require '../managers/transactions/giftCardTransactionManager'
timeAndDate                   = require '../modules/timeAndDateFunctions'


###
  About Gift Cards
  
  Gift cards are initiated with a balance, but with active flag set to false. This
    allows for a gift card placeholder to reserve a given gift card code (unique) 
    while not allowing the card to be redeemable. 
    
  The Check Manager is responsible for collecting funds and notifying this Gift Card
    Manager that the gift card is paid for and can be activated.
  
  Gift card track the check used to create them. The locationId could be 
    derived from the check, but is used frequently enough in reporting and queries, 
    that it is stored here for convenience.
    
  'code' is usique and is the human readable code as seen by the customer. 
  
  'startBalance' is the original balance of the card. The cumulative effect of all transactions
    on a given giftcard should always equate to the difference between the 'startBalance' and
    'balance'
  
  During migration a gift card may be partially redeemed. A summary transaction is created that 
    brings the 'balance' down (or potentially up) to the correct amount. 
###


class GiftCard extends baseModel
  constructor: (data) ->
    super('giftCard')
    @_id =              data['_id'] ? null
    @checkId =          data['checkId'] ? null
    @purchasedById =    data['purchasedById'] ? null
    @locationId =       data['locationId'] ? null
    @code =             data['code'] ? null
    @startBalance =     data['startBalance'] ? null
    @balance =          data['balance'] ? null
    @active =           data['active'] ? false
    @created =          data['created'] ? (new Date().getTime())
    
  get_as_json: () ->
    data = {
      '_id': @_id
      'checkId': @checkId
      'purchasedById': @purchasedById
      'locationId': @locationId
      'code': @code
      'startBalance': @startBalance
      'balance': @balance
      'active': @active
      'created': @created
    }
    return data
    
  save: (callback) -> 
    @_id = new ObjectId() if not @_id?
    [errors, valid] = @validate()
    if not valid then return callback errors, null
    mongoManager.saveModel "giftCards", @_id, @get_as_json(), (err, result) => 
      return callback err, null if err?
      return callback null, result if callback?
      
  remove: (callback) ->
    mongoManager.removeByID "giftCards", @_id, (err, result) => 
      return callback err, null if err?
      return callback null, result if callback?
       
  activate: (callback) ->
    data = {'$set': {'active': true}}
    mongoManager.updateModel "giftCards", @_id, data, (err, result) => 
      return callback err, null if err?
      return callback null, result if callback?
    
  updateBalance: (amount, callback) ->
    data = {'$inc': {'balance': amount}}
    mongoManager.updateModel "giftCards", @_id, data, (err, result) => 
      return callback err, null if err?
      return callback null, result if callback?
  
  validate: () ->
    errors = []
    if @code.length < 8
      errors.push "Gift cards must be at least 8 characters long. Code: #{@code}"
    if isNaN @balance or @balance <= 0
      errors.push 'Gift cards must have a positive balance'
    return [errors, errors.length == 0]
      
      


    

class GiftCardManager extends baseManager
  constructor: ->
    super( 'giftCard', GiftCard )
       
  ###
    Gift cards sales are viewed so frequently by managers (especially during holiday season)
      that it is worth keeping a running cache of key sales volume stats. Each night this cache
      gets rebuilt.
  ###  
  databaseIsReady: () ->
    @setupCron()
    
  setupCron: () ->
    handler = (job) => @cronTask job
    cronManager.registerJobHandler 'giftcardSalesDataCache', handler, () =>
      t = (new Date()).getTime()
      @scheduleJob null, null, t
    
  scheduleJob: (lastRunTime, nextRunMidnight, runNow) ->
    if runNow?
      runTime = runNow
    else
      nextRunMidnight = timeAndDate.getTomorrowMidnight lastRunTime if not nextRunMidnight?
      runTime = nextRunMidnight + 9.5*3600*1000
    params = { name: 'Giftcard Sales Data Cache', runTime: runTime }
    cronManager.scheduleJob 'giftcardSalesDataCache', runTime, params, (err, id) -> return
      
  cronTask: (job) ->
    @buildSalesDataCache job, (err, success) =>
      return log.criticalError err, "CRITICAL ERROR giftcardSalesDataCache" if err?
      cronManager.jobCompleted job
      @scheduleJob job.params.runTime, null
      
      
      
      
    
  ########################################################################
  ######## Builds and serves a summary of the gift card sales data #######
  ########################################################################
    
  buildSalesDataCache: (job, callback) ->
    locations = null
    locationOffsets = null
    salesData = {}
    endTime = (new Date()).getTime()
      
    done = () =>
      @salesData = salesData
      callback null, true
      
    nextLocation = (err, result) =>
      return callback err, null if err?
      location = locations.shift()
      return done() if not location?
      salesData[location._id] = {
        'today': {'count': 0, 'total': 0}
        'weekToDate': {'count': 0, 'total': 0}
        'monthToDate': {'count': 0, 'total': 0}
      }
        
      startOfDayTime = getStartOfDayFromEndTime endTime, offsets
      startOfWeekTime = getStartOfWeekFromEndTime endTime, offsets
      startOfMonthTime = getStartOfMonthFromEndTime endTime, offsets
      
      offsets = locationOffsets[location._id]

      query = {
        'locationId': location._id
        'active': true
        'created': {'$gte': startOfMonthTime}
      }
      @getManyBy query, (err, models) =>
        return callback err, null if err?
        for m in models ? []
          keys = ['monthToDate']
          keys.push 'weekToDate' if m.created >= startOfWeekTime
          keys.push 'today' if m.created >= startOfDayTime
          for key in keys
            salesData[location._id][key].count++
            salesData[location._id][key].total+= m.startBalance
        
        nextLocation()
    
    locationManager.getCachedOffsets (err, offsets) ->
      return callback err, null if err?
      locationOffsets = offsets
      query = {'active': true}
      locationManager.getManyBy query, (err, models) ->
        return callback err, null if err?
        locations = (m.get_as_json() for m in models)
        nextLocation null, null
        
  serveSalesData: (req, res) ->
    callback = (err) =>
      response_data = { result: !err?, errors: err }
      response_data['salesData'] = @salesData?[locationId] ? null
      return res.json response_data
      
    for k,v of req.user?.device?.role.locationIds ? {}
      locationId = k
      break
    return callback "no device locationId found." if not locationId?
    return callback "no gift card sales data found for locationId: #{locationId}" if not @salesData?[locationId]?
    callback null
    
  ########################################################################
  ########################################################################
  ########################################################################
  
  
      
  # Helper for frequent reporting query used with nightly reporting
  getCheckGiftCards: (checkIds, callback) ->
    @getManyBy {'checkId':{"$in": checkIds}}, callback
    
  
  # A check, once closed, will require it's giftcards to be activated, meaning the 
  # giftcard will now be usable.
  activateCheckGiftCards: (checkId, giftcardIds, callback) ->
    giftcards = null
    
    updateCachedSalesData = (giftcard, callback) =>
      locationManager.getCachedOffsets (err, locationOffsets) =>
        return callback err, null if err?
        offsets = locationOffsets[giftcard.locationId] ? null
        return if not offsets?
        
        et = (new Date()).getTime()
        startOfDayTime = getStartOfDayFromEndTime et, offsets
        startOfWeekTime = getStartOfWeekFromEndTime et, offsets
        startOfMonthTime = getStartOfMonthFromEndTime et, offsets
              
        keys = ['monthToDate']
        keys.push 'weekToDate' if giftcard.created >= startOfWeekTime
        keys.push 'today' if giftcard.created >= startOfDayTime
        for key in keys
          if @salesData?[giftcard.locationId]?[key]?
            @salesData[giftcard.locationId][key].count++
            @salesData[giftcard.locationId][key].total+= giftcard.startBalance
        callback()          
    
    nextGiftCard = (err, model) ->
      return callback err if err?
      giftcard = giftcards.shift()
      return callback null, true if not giftcard?
      giftcard.activate (err, result) ->
        return callback err if err?
        updateCachedSalesData giftcard, () ->
          nextGiftCard()
    
    giftCardsCallback = (err, models) ->
      return callback err if err?
      giftcards = models
      nextGiftCard()
    
    query = {
      '_id':{'$in':giftcardIds}
      'checkId': checkId
    }
    @getManyBy query, giftCardsCallback
    
  
  serveOne: (req, res) ->
    callback = (err, giftCard) ->
      response_data = { result: !err?, errors: err }
      response_data['giftCard'] = giftCard.get_as_json() if giftCard?
      return res.json response_data
      
    @getBy {'code': req.params.code}, (err, model) ->
      return callback err if err?
      return callback 'Gift card does not exist', null if not model?
      return callback null, model
      
  
  # serves all transactions (credits and debits) for a given gift card. Used to build a complete
  # historical log of the card activity. 
  serveTransactions: (req, res) ->
    callback = (err, transactions) ->
      response_data = { result: !err?, errors: err }
      response_data['transactions'] = (t.get_as_json() for t in (transactions ? []))
      return res.json response_data
      
    permissionCheck = () ->
      role = req.user.role
      for roleName in ['corporateMgr', 'adminMgr', 'groupMgr', 'locationMgr', 'reception']
        return true if role[roleName]?
      return false
    
    giftCardId = req.params.id
    return callback "permission denied" if not permissionCheck()
    return callback "requests for gift card transactions require a giftCardId parameter." if not giftCardId?
    
    giftCardTransactionManager.getManyBy {'giftCardId': giftCardId}, (err, models) ->
      return callback err, models
        
      

  add: (req, res) ->
    callback = (err, giftCard) =>
      response_data = { result: !err?, errors: err }
      response_data['giftCard'] = giftCard.get_as_json() if giftCard?
      return res.json response_data
    @addModel req.body, callback
  
  addModel: (body, callback) ->
    newGiftCardCallback = (err, doc) =>
      return callback err, null if err?
      giftCard = new GiftCard doc
      callback null, giftCard
      
    makeGiftCard = () ->
      body.active = false if not body.active
      body.startBalance = body.balance if not body.startBalance?
      giftCard = new GiftCard body
      giftCard.save newGiftCardCallback
      
    @getBy {'code': body.code}, (err, giftCard) ->
      return callback err, null if err?
      return callback 'Gift card already exists', null if giftCard?
      makeGiftCard()
    
  
    
    
  addTransaction: (req, res) ->
    body = req.body
    giftcard = null
    total = null
    tip = null
    
    callback = (err, transaction) ->
      response_data = { result: !err?, errors: err }
      response_data['giftcardTransactionData'] = transaction if transaction?
      return res.json response_data
      
    transactionCallback = (err, result) ->
      return callback err, null if err?
      return callback "no transaction result returned", if not result?
      
      transaction = if result.child ? result
      transaction = transaction.get_as_json()
        
      transaction.code = giftcard.code
      transaction.remainingBalance = giftcard.balance
      callback null, transaction
      
    reverseBalanceCallback = (err, doc) ->
      return callback err, null if err?
      return callback 'The giftcard transaction failed. Please try again.', null
        
    updatedBalanceCallback = (err, doc) =>
      return callback err, null if err?
      return giftcard.updateBalance total, reverseBalanceCallback if doc.balance < 0
      giftcard.balance = doc.balance
      body.giftCardId = giftcard._id
      body.employeeUserId = req.user.operator._id
      body.locationId = (k for k,v of req.user.device.role.locationIds)[0]
      giftCardTransactionManager.addTransaction body, transactionCallback
    
    giftCardCallback = (err, model) ->
      return callback err, null if err?
      return callback "Gift card not found", null if not model?
      return callback "Gift card has no balance", null if model.balance <= 0 and body.total > 0    
      giftcard = model
      
      if body.total > 0
        if giftcard.balance >= body.total
          total = body.total
          tip = body.tip
        else
          total = giftcard.balance
          short = body.total - total
          tip = Math.max(0, tip-short)
      else
        total = body.total
        tip = body.tip
      
      body.total = total
      giftcard.updateBalance -total, updatedBalanceCallback
    
    @getBy {'code': body.code, 'active': true}, giftCardCallback
    
    
  reverseTransaction: (req, res) ->
    transaction = null
    
    callback = (err, data) ->
      response_data = { result: !err?, errors: err }
      response_data['giftcardTransactionData'] = data if data?
      return res.json response_data
      
    balanceUpdatedCallback = (err, doc) ->
      return callback err, null if err?
      data = transaction.get_as_json()
      data.code = doc.code
      data.remainingBalance = doc.balance
      callback null, data
      
    giftCardAccountCallback = (err, model) ->
      return callback err, null if err?
      return callback 'unable to find gift card account', null if not model?
      giftCardAccount = model
      giftCardAccount.updateBalance transaction.total, balanceUpdatedCallback
      
    reversedTransactionCallback = (err, doc) =>
      return callback err, null if err?
      @get transaction.giftCardId, giftCardAccountCallback
      
    transactionCallback = (err, model) ->
      return callback err, null if err?
      return callback 'unable to find gift card transaction', null if not model?
      transaction = model
      transaction.reverse reversedTransactionCallback
      
    giftCardTransactionManager.get req.params.giftCardTransactionId, transactionCallback
  
    
  remove: (req, res) ->
    callback = (err, result) =>
      response_data = { result: !err?, errors: err }
      return res.json response_data
      
    getGiftCardCallback = (err, giftCard) ->
      return callback err, null if err?
      return callback 'Gift card does not exist', null if not giftCard?
      giftCard.remove callback
    
    @get req.params.id, getGiftCardCallback
    

    

module.exports = new GiftCardManager





# local Offset is going to be zero on a GMT server, but this makes the adjustment
# when running on a machine in a different TZ
getTZAdjustedEndTime = (endTime, offsets) ->
  localOffset = (new Date(endTime)).getTimezoneOffset()/60
  offset = timeAndDate.getTZOffset endTime, offsets
  localAdjustedOffset = offset + localOffset
  offsetInMS = localAdjustedOffset * 3600000
  adjustedEndTime = endTime + offsetInMS
  return adjustedEndTime
    
getStartOfDayFromEndTime = (endTime, offsets) ->
  t = getTZAdjustedEndTime endTime, offsets
  return timeAndDate.GetDayTime t
  
getStartOfWeekFromEndTime = (endTime, offsets) ->
  t = getTZAdjustedEndTime endTime, offsets
  return timeAndDate.GetWeekTime t
  
getStartOfMonthFromEndTime = (endTime, offsets) ->
  t = getTZAdjustedEndTime endTime, offsets
  return timeAndDate.GetMonthTime t
  