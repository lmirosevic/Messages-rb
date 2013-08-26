Messages
============

A generic messaging implementation backed by MongoDB. Supports collections, messages, custom payloads, read states, in-memory manipulation & faulting.

Example
------------

Include the module to save some typing:
```ruby
include Goonbee:Messages
```

Creating a collection with some messages:

```ruby
#Create a collection, give it a type and add some meta info (which can be any JSON serializable dictionary):
collection1 = Collection.create({:type => 'qa', :meta => {:item => '123', :seller => 'luka'}})


#Create a message, give it an author, type, and payload (which can be any JSON serializable dictionary). This time it's of type 'question':
question = Message.create({:author => 'Jack Dorsey', :type => 'question', :payload => 'Will it still work if I plug in 20 guitars?'})


#Create another message, this time it's of type 'answer':
answer = Message.create({:author => 'Luka Mirosevic', :type => 'answer', :payload => 'No, you\'ll probably see a fail whale.'})


#Add both message to the collection, this is now in memory and nothing has been written to the database yet:
collection1.add_messages(question, answer)


#This commits the in memory reporesentation to the DB:
collection1.save
```

Update an existing message:

```ruby
#Change some properties
question.author = 'Tim Cook'
```

#Now commit that change to the DB:
question.save
```

Replace an existing message in a collection:

```ruby
#Create a new message:
new_answer = Message.create({:author => 'Luka Mirosevic', :type => 'answer', :payload => 'I hate fail whales.'})

#Replace the existing message in collection1 at position 1 with the new one:
collection1.set_message_at(1, new_answer)

#Commit these changes:
collection1.save
```

Create a new collection and add an existing message and a new message to it:

```ruby
#Create a new collection:
collection2 = Collection.create({:type => 'bla', :meta => {:item => '123', :seller => 'luka'}})

#Add that new answer that we made, that message is now part of 2 collections, that's no problem:
collection2.add_message(new_answer)

#We can create yet another message...:
another_message = Message.create({:author => 'charlie', :type => 'comment', :payload => 'Hi guys!'})

#...and add it to the second collection:
collection2.add_message(another_message)

#commit to DB:
collection2.save
```

You should use `save` sparingly as it serializes the in memory representation to the database, which might require several round trips to the DB and so is very expensive.

Dependencies
------------

* [Toolbox-rb](https://github.com/lmirosevic/Toolbox-rb)

Copyright & License
------------

Copyright 2013 Luka Mirosevic

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this work except in compliance with the License. You may obtain a copy of the License in the LICENSE file, or at:

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.