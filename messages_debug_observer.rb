# encoding: UTF-8

# messages_debug_observer.rb
# Goonbee Messages
#
# Created by Luka Mirosevic on 27/04/2013.
# Copyright (c) 2013 Goonbee. All rights reserved.

class MessagesDebugObserver
   def created_collection(collection_id)
       p "created_collection: #{collection_id}"
   end

   def deleted_collection(collection_id)
       p "deleted_collection: #{collection_id}"
   end

   def updated_collection(collection_id)
       p "updated_collection: #{collection_id}"
   end

   def appended_message_to_collection(collection_id, message_id)
       p "appended_message_to_collection: #{collection_id}, #{message_id}"
   end

   def removed_message_from_collection(collection_id, message_id)
       p "removed_message_from_collection: #{collection_id}, #{message_id}"
   end

   def created_message(message_id)
       p "created_message: #{message_id}"
   end

   def deleted_message(message_id)
       p "deleted_message: #{message_id}"
   end

   def updated_message(message_id)
       p "updated_message: #{message_id}"
   end

   def user_read_message(message_id, user_id)
     p "user_read_message: #{message_id} #{user_id}"
   end
end