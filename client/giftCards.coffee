window.InitializeGiftcardsSetup = (App) ->
  
  ###
    About Giftcards
    
    Gift cards are represented by a single mongo document that describe a snapshot
      of the curent card properties, essentially, this shows the current balance
      
    Gift card balances are effected by Gift card transactions. The current balance
      is always equal to the cumulative total of all related gift card transactions.
      Typically there is one debit transaction (at purchase) and one or many debit
      transactions (redemption).
      
    Migration Note: Not all histprical transactions could be migrated. In such a case
      a balancing transaction puts the car dback in balance, but does not show a 
      detailed log of the underlying transaction. For display purposes this is shown as 
      pre migration activity which is the highest level of accruacy available given the data
      available during migration. 
      
    Gift cards may, or may NOT, belong to the location viewing the card. When it does, this
      is referred to as the cards 'home' location.
    
  ###

  Ember.Handlebars.helper 'asLocationNameOrCorporate', (locationId) ->
    return 'corporate' if not locationId?
    return "" if not locationId? or not window.db.locations?
    location = window.db.locations[locationId]
    return location?.name ? ""
    
    
  App.Transaction = Ember.Object.extend {
    negativeTotal: (->
      return -@total
    ).property('total')
    
    isHomeLocation: (->
      return @locationId == db.locationId
    ).property('locationId')
  }
  
  App.GiftCard = Ember.Object.extend {
    transactions: null
    missingBalance: null
    
    init: () ->
      this._super()
      
    addTransaction: (transaction) ->
      @transactions.addObject App.Transaction.create transaction
      newBalance = @balance - transaction.total
      @set 'balance', newBalance
      
    setTransactions: (transactions) ->
      data = []
      for t in transactions
        data.addObject App.Transaction.create t
      @set 'transactions', data
      @setMissingTransactionAmount()
      
    setMissingTransactionAmount: () ->
      # Data migration helper
      # If balance is not sum of startBalance and transactions, then transactions took place outside
      # of the application (LMS) so requires an entry to explain this to user.
      transactionsTotal = 0
      for t in @transactions
        transactionsTotal += t.total
      if @startBalance - transactionsTotal > @balance
        @set 'missingBalance', @balance - (@startBalance - transactionsTotal)
    
      
  }
  
  
  App.GiftcardsController = Ember.ObjectController.extend {
    operator: null
    device: null
    isReady: null
    giftcard: null
    giftcardString: null
    changeBalanceBy: 0
    newGiftcard: null
    locationOptions: null
    giftCardSalesData: null
    
    init: () ->
      @_super()
      db.giftcards = {}
      @set 'operator', window.db.user.operator ? null
      @set 'device', window.db.user.device ? null
      @set 'newGiftcard', {}
      
      App.dBLoader.registerIsReadyCallback () =>
        @dbIsReady()
        
    dbIsReady: () ->
      @set 'locationOptions', buildLocationOptions()
      @set 'isReady', true
      @loadGiftCardSalesData()
    
    actions:
      getGiftCardBalance: -> @doGetGiftCardBalance()
      updateGiftCardBalance: -> @doUpdateGiftCardBalance()
      addNewGiftCard: -> @doAddNewGiftCard() 
      
    loadGiftCardSalesData: () ->
      $.ajax( {
        type: "GET"
        url: "/api/1/giftCards/salesData"
        contentType: "application/json; charset=utf-8"
      }).done ( result ) =>
        if result.result
          @set 'giftCardSalesData', result.salesData
        else
          showErrors result.errors
      
    doAddNewGiftCard: () ->
      validateNewGiftCard = () =>
        errors = []
        if not @newGiftcard.balance? or @newGiftcard.balance < 0
          errors.push "Enter a positive amount for the gift card starting balance."
        if not @newGiftcard.code? or @newGiftcard.code.length < 8
          errors.push "Enter a gift card code that is at least 8 characters long."
        return [errors, errors.length == 0]
        
      [errors, valid] = validateNewGiftCard()
      return showErrors errors if not valid
      
      data = {
        'locationId': @newGiftcard.locationId
        'code': @newGiftcard.code
        'balance': @newGiftcard.balance * 100
      }
      
      parent = {}
      buttons = [
        { title: "Yes", danger: true, function: => @whenAddGiftCardConfirmed parent, data }
        { title: "No", function: -> return }
      ]
      
      parent.modal = launchModalDialog {
        message: "Are you absolutely sure you want to add a new gift card?" 
        buttons: buttons
      }
      
    whenAddGiftCardConfirmed: (parent, data) ->
      parent.modal.dismiss()
      @set 'newGiftcard', {}
      waiting = launchModalDialog { message: "adding gift card..." }
      $.ajax( {
        type: "POST"
        url: "/api/1/giftCards/"
        data: JSON.stringify data
        contentType: "application/json; charset=utf-8"
      }).done ( result ) =>
        waiting.dismiss()
        if result.result
          @set 'giftcard', App.GiftCard.create result.giftCard
        else
          showErrors result.errors
        
    doGetGiftCardBalance: () ->
      code = cleanGiftCardCode @giftcardString
        
      if db.giftcards[code]?
        return @set 'giftcard', db.giftcards[code]
        
      $.getJSON("/api/1/giftCards/balance/#{code}")
        .done (data) =>
          if data.result
            if data.giftCard?
              gc = App.GiftCard.create data.giftCard
              db.giftcards[data.giftCard.code] = gc
              @set 'giftcard', gc
            else
              @set 'giftcard', null
              showErrors "Gift card code not found"
          else
            showErrors data.errors
            
    loadGiftcardHistory: () ->
      return if not @giftcard
      $.getJSON("/api/1/giftCards/#{@giftcard._id}/transactions/")
        .done (data) =>
          if data.result
            @setTransactions data.transactions
          else
            showErrors data.errors
    
    setTransactions: (transactions) ->
      return if not @giftcard?
      @giftcard.setTransactions transactions
      
    doUpdateGiftCardBalance: () ->
      parent = {}
      buttons = [
        { title: "Yes", danger: true, function: => @whenUpdateGiftCardBalanceConfirmed parent }
        { title: "No", function: -> return }
      ]
      
      parent.modal = launchModalDialog {
        message: "Are you absolutely sure you want to update the gift card balance?" 
        buttons: buttons
      }
      
    whenUpdateGiftCardBalanceConfirmed: (parent) ->
      parent.modal.dismiss()
      data = @getTransactionData()
      @set 'changeBalanceBy', 0
      return if not data
      waiting = launchModalDialog { message: "updating gift card..." }
      $.ajax({
        type: "POST"
        url: "/api/1/giftCards/transactions/"
        data: JSON.stringify data
        contentType: "application/json; charset=utf-8"
      }).error ( err ) =>
        waiting.dismiss()
        showErrors "http error [#{err.status}]: #{err.statusText}"
      .done ( result ) =>
        waiting.dismiss()
        if result.result
          @giftcard?.addTransaction result.giftcardTransactionData
        else
          return showErrors result.errors
      
    getTransactionData: () ->
      return null if not @giftcard?
      data = {
        'giftCardId': @giftcard._id
        'checkId': null
        'locationId': null
        'code': @giftcard.code
        'total': -(@changeBalanceBy ? 0) * 100
      }
              
    
    # Observers
            
    giftCardStringDidChange: (->
      if db.giftcards[@giftcardString]?
        return @set 'giftcard', db.giftcards[@giftcardString]
      if @giftcard?
        if @giftcardString != @giftcard.code
          @set 'giftcard', null
    ).observes('giftcardString')
    
    giftcardDidChange: (->
      @set 'changeBalanceBy', 0
      @loadGiftcardHistory()
    ).observes('giftcard')   
         
 
    # Computed Properties
    
    hasAccess: (->
      for r in ['corporateMgr', 'adminMgr']
        return true if @operator?.role[r]?
      return true if @device?.role['reception']? and db.locationId?
      return false
    ).property('operator', 'device')
    
    canEdit: (->
      for r in ['corporateMgr', 'adminMgr']
        return true if @operator?.role[r]?
      return false
    ).property('operator')
  }
  
    
  App.giftcardsController = new App.GiftcardsController


  App.GiftcardsView = Em.View.extend {
    templateName: "giftcards/giftcards"
    controller: App.giftcardsController
    
    didInsertElement: (event) ->
      @_super()
  }

    
    
    
    
    
buildLocationOptions = () ->
  options = []
  for k,v of db.locations
    options.push {'name': v.name, 'value': k}
  options.sort (a,b) -> sortBy('name', a, b)
  return options
    