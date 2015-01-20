# giftCardManager (server)
Sample Collection (Manager) &amp; Document (Model) classes for gift card API

These classes work together as a Manager (gift card collection) and Model (gift card document) and 
handle the carious API calls made to the giftCard route.

Manager extends BaseManager - which provides basic queries (id lookup, find one, find many) and add, remove, update methods. 
These methods should be overridden where neccessary to accomodate custom gift card behaviour.

Model extends BaseModel - which provides basic save, update, and delete queries, and should be overridden as neccessary.

MongoManager is used by the base classes (BaseManager and BaseModel) for communication with Mongo, however, these 
classes can access MongoManager directly. These classes should never establish a direct connection to the DB, and always 
comunicate via their respective Base classes or via MongoManager directly.

These classes are built in coffeescript and intended as a guide for a typical Manager/Model handling API calls.


# giftcards.coffee, giftcards.hbs (client)
giftcards.coffee initializes the Ember controller and object for giftcards and works with the handlebars template giftcards.hbs

Base of these files are utilized by the base giftcards/application.coffee and giftcards/application.hbs files which are thin wrappers that follow the applications typical initialization of a view. For example, application coffee would trigger any set up data loading (see dbLoader smaple code) and create the top level App (Ember.App). giftcards/application.hbs provides headers/footers and some high level div wrappers utilizing base styling classes. There should be no need to edit any of these while customizing the giftcards view. 
