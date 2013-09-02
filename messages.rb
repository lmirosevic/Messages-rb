# encoding: UTF-8

# messages.rb
# Goonbee Messages
#
# Created by Luka Mirosevic on 27/04/2013.
# Copyright (c) 2013 Goonbee. All rights reserved.

#foo implement object verification

require 'mongo'
require 'json'
require 'bson'
require 'time'

require './lib/Goonbee/Toolbox/toolbox'

module Goonbee
    module Messages
        class MessagesError < StandardError
        end

        class NotConnectedError < MessagesError
        end

        class ObjectNotFoundError < MessagesError
        end

        class VerificationFailedError < MessagesError
        end

        module Syncable
            attr_accessor :last_hash, :last_hash_core

            def synced?
                last_hash == serialize.hash
            end

            def synced_core?
                last_hash_core == serialize_core.hash
            end

            def did_sync
                self.last_hash = serialize.hash
                self.last_hash_core = serialize_core.hash
            end
        end

        class Manager
            class << self
                attr_accessor :notifications_object
                alias_method :register_notifications_object, :notifications_object=
                alias_method :no, :notifications_object

                def connect(client)
                    @mongo = client
                    @connected = true
                end

                def mongo
                    #reconnect if needed
                    @mongo.connect unless @mongo.connected?

                    #return main DB
                    @mongo[ENV['MESSAGES_DATABASE']]
                end

                def connected
                    @connected
                end

                def messages
                    mongo.collection('messages')
                end

                def collections
                    mongo.collection('collections')
                end

                def cache
                    #lazy creation of root container
                    @cache = Hash.new unless @cache

                    @cache
                end

                def add_to_cache(bucket, id, item)
                    unless in_cache?(bucket, id)
                        #lazily create the bucket
                        @cache[bucket] = Hash.new unless @cache[bucket]

                        cache[bucket][id] = item
                    end
                end

                def remove_from_cache(bucket, id)
                    if in_cache?(bucket, id)
                        cache[bucket].delete(id)
                    end
                end

                def in_cache?(bucket, id)
                    cache.has_key?(bucket) && cache[bucket].has_key?(id)
                end

                def get_from_cache(bucket, id)
                    if in_cache?(bucket, id)
                        cache[bucket][id]
                    end
                end

                def clear_cache
                    @cache = nil
                end

            end
        end

        class Item
            def self.new(*args, &block)
                #each type of obj will be in its own bucket, this prevents accidentally returning a message when the user creates a collecion if there happens to be a message cached with that id
                bucket = name

                #check if it has an id field and if that is in the cache
                if (args[0].is_a?(Hash)) && (id = args[0][:_id ] || args[0][:id]) && (Manager.in_cache?(bucket, id))
                    #return the cached object
                    Manager.get_from_cache(bucket, id)
                else
                    #create a new one
                    new_object = allocate
                    new_object.send(:initialize, *args, &block)

                    #store it in the cache
                    id = new_object.id
                    Manager.add_to_cache(bucket, id, new_object) unless id.nil?

                    #return it
                    new_object
                end
            end

            def self.new_fault(id)
                new(:id => id, :fault => true)
            end

            def self.load_from_server(id)
                new_fault(id).load_from_server
            end

            def load_from_server
                return self unless fault?
                Manager.connected or raise NotConnectedError

                if id && (document = _load_from_server(id))
                    initialize(document.symbolize_keys.merge({:fault => false}))
                    did_sync
                    self
                else
                    raise ObjectNotFoundError
                end
            end

            def initialize(opts={})
                @changes = []
            end

            def fault?
                @fault
            end

        protected
            def fault=(fault)
                @fault = fault
        end

        attr_accessor :changes
            def _observe(what, details=nil)
          if (what != :updated) || (!changes.any? {|i| i.key?(:created)})
             changes.push({what => details})
          end
            end
        end

        class Collection < Item
            include Syncable

            attr_accessor :type, :meta
            attr_reader :id, :created_date, :updated_date

            def self.exists?(id)
                Manager.collections.find({:_id=>id}).limit(1).count == 1
            end

            def self.unread_count_for_collections(collection_ids, user_id)
                #convert them to objectids
                collection_objectids = collection_ids.map{ |e| BSON::ObjectId.from_string(e) }

                #find all of those collections
                collections = Manager.collections.find({:_id => {:'$in' => collection_objectids}}, {:fields => {:messages => 1}})

                #get all the message ids for all the collections
                all_message_ids = []
                collections.each { |collection| all_message_ids.concat(collection['messages']) }

                #convert those to objectids
                message_objectids = all_message_ids.map{ |e| BSON::ObjectId.from_string(e) }

                #get the unread count
                unread_count = Manager.messages.find({:_id => {:'$in' => message_objectids}, :'read' => {'$ne' => user_id}}).count

                #return the count
                unread_count
            end

            def initialize(opts={})
                #create a new one
                super
                @id = (opts[:_id] ? opts[:_id].to_s : false) || opts[:id] || nil
                @type = opts[:type] || nil
                @meta = opts[:meta] || nil
                @messages = opts[:messages] ? opts[:messages].map do |i|
                    if i.kind_of?(String)
                        Message.new_fault(i)
                    elsif i.kind_of?(Message)
                        i
                    end
                end : nil
                @created_date = opts[:createdDate] || nil
                @updated_date = opts[:updatedDate] || nil

                self.fault = opts[:fault]

                self
            end

            def self.create(opts={})
                #set some defaults if needed
                opts[:_id] ||= BSON::ObjectId.new.to_s
                opts[:type] ||= 'None'
                opts[:messages] ||= []
                opts[:createdDate] ||= Time.now.utc.iso8601

                new_object = new(opts.merge({:fault=>false}))
                new_object.send(:_observe, :created)
                new_object
            end

            def synced_deep?
                synced? && messages.all? {|i| i.synced?}
            end

            def synced_core_deep?
                synced? && messages.all? {|i| i.synced_core?}
            end

            def save
                Manager.connected or raise NotConnectedError

                #set updated field only if the core properties have changed
                if !fault? && !synced_core_deep?
                    #set updated field
                    @updated_date = Time.now.utc.iso8601
                end

                #only save it if it's not a fault
                if !fault? && !synced_deep?
                    #first verify the collection
                    verify or raise VerificationFailedError

                    #save all the messages in the collection
                    _messages.each {|i| i.save}#foo used to be message.each, which did a deep load

                    #remember that we changed sth about him
                    _observe(:updated)

                    #tell observer
                    _notify_observer

                    #now save the collection itself
                    Manager.collections.save(serialize)

                    #remember our current hash
                    did_sync

                    self
                else
                    nil
                end
            end

            def delete
                #record this
                _observe(:deleted)

                #tell observer
                _notify_observer

                #remove yourself from cache
                Manager.remove_from_cache(self.class.name, id)

                #now remove yourself from server
                Manager.collections.remove({:_id => BSON::ObjectId.from_string(id)})

                #for safety, zero this object
                initialize
            end

            #marks all message in a collection as read/unread
            def set_user_read_all(user_id, did_read)
                self.messages.each {|m| m.set_user_read(user_id, did_read)}
            end

            def user_has_unread_messages?(user_id)
                !user_read_all?(user_id)
            end

            def user_read_all?(user_id)
                messages.all? {|i| i.user_read?(user_id)}
            end

            def user_unread_messages(user_id)
                messages.count {|message| message.user_read?(user_id)}
            end

            def remove_message_at(index)
                _remove_message_at(index)
            end

            def remove_message(message)
                _remove_message(message)
            end

            def remove_all_messages
                until messages.empty? do
                    remove_message_at(messages.count-1)
                end
            end

            def length
                _messages.length
            end

            def messages
                _messages.map {|i| i.load_from_server}
            end

            def message_ids
                _messages.map {|i| i.id}
            end

            def message_count
                @messages.count
            end

            def message_at(index)
                message = _message_at(index)
                message.load_from_server unless message.nil?
            end

            def message_id_at(index)
                message = _message_at(index)
                message.id unless message.nil?
            end

            def set_message_at(index, message)
                _set_message_at(index, message)
            end

            def set_message_id_at(index, message_id)
                _set_message_at(index, Message.new_fault(message_id))
            end

            def add_message(message)
                set_message_at(_messages.count, message)#foo used to be messages.count which did a deep load
            end

            def add_message_id(message_id)
                set_message_id_at(messages.count, message_id)
            end

            def add_messages(*messages)
                messages.each {|i| add_message(i)}
            end

            def add_message_ids(*message_ids)
                message_ids.each {|i| add_message_id(i)}
            end

            def last_message
                _last_message.load_from_server
            end

            def last_message_id
                _last_message.id
            end

            def user_last_unread_message(user_id)
                message = _user_last_unread_message(user_id)
                message.load_from_server unless message.nil?
            end

            def user_last_unread_message_id(user_id)
                message = _user_last_unread_message(user_id)
                message.id unless message.nil?
            end

            def serialize
                {
                    :_id => BSON::ObjectId.from_string(@id),
                    :type => @type,
                    :meta => @meta,
                    :messages => @messages.map {|i| i.id},
                    :createdDate => @created_date,
                    :updatedDate => @updated_date,
                }
            end

            def serialize_core
                {
                    :_id => BSON::ObjectId.from_string(@id),
                    :type => @type,
                    :meta => @meta,
                    :messages => @messages.map {|i| i.id},
                }
            end

            def serialize_deep
                {
                    :_id => BSON::ObjectId.from_string(@id),
                    :type => @type,
                    :meta => @meta,
                    :messages => @messages.map {|i| i.load_from_server.serialize},
                    :createdDate => @created_date,
                    :updatedDate => @updated_date,
                }
            end

            def verify#todo
                true#foo stub
            end

        protected
            def _load_from_server(id)
                Manager.collections.find_one({:_id => BSON::ObjectId.from_string(id)})
            end

        private
            def _notify_observer
                #loop through changes array
                changes.uniq.each do |i|
                    #loop through all kv pairs in the hash
                    i.each do |k, v|
                        case k
                        when :created
                            Manager.no.created_collection(id) if Manager.no.respond_to?(:created_collection)
                        when :deleted
                            Manager.no.deleted_collection(id) if Manager.no.respond_to?(:deleted_collection)
                        when :updated
                            Manager.no.updated_collection(id) if Manager.no.respond_to?(:updated_collection)
                        when :appended
                            Manager.no.appended_message_to_collection(id, v) if Manager.no.respond_to?(:appended_message_to_collection)
                        when :removed
                            Manager.no.removed_message_from_collection(id, v) if Manager.no.respond_to?(:removed_message_from_collection)
                        else
                            #noop
                        end
                    end
                end
                changes.clear
            end

            def _set_message_at(index, message)
                if index && message
                    #remove the old one
                    _remove_message_at(index)

                    #remember this
                    _observe(:appended, message.id)

                    #store it
                    _messages[index] = message
                end

                nil
            end

            def _remove_message(message)
                index = messages.find_index(message)
                _remove_message_at(index)
            end

            def _remove_message_at(index)
                if index < _messages.count
                    #remember this
                    _observe(:removed, _messages[index].id)

                    #do the actual removal
                    _messages.delete_at(index)
                end

                nil
            end

            def _messages
                @messages
            end

            def _message_at(index)
                @messages[index]
            end

            def _last_message
                @messages[-1] unless @messages.nil?
            end

            def _user_last_unread_message(user_id)
                messages.reverse_each do |i|
                    i.load_from_server
                    return i unless i.user_read?(user_id)
                end unless messages.nil?
                nil
            end
        end

        class Message < Item
            include Syncable

            attr_accessor :type, :payload, :author, :read
            attr_reader :id, :updated_date

            def self.exists?(id)
                Manager.messages.find({:_id=>id}).limit(1).count == 1
            end

            def initialize(opts={})
                super

                @id = (opts[:_id ] ? opts[:_id].to_s : false) || opts[:id]
                @type = opts[:type] || nil
                @payload = opts[:payload] || nil
                @updated_date = opts[:updatedDate] || nil
                @author = opts[:author] || opts[:authorID] || nil
                @read = opts[:read] || nil

                self.fault = opts[:fault]

                self
            end

            def self.create(opts={})
                #set some defaults if needed
                opts[:_id] ||= BSON::ObjectId.new
                opts[:type] ||= 'None'
                opts[:read] ||= []

                new_object = new(opts.merge({:fault=>false}))
                new_object.send(:_observe, :created)
                new_object
            end

            def save
                Manager.connected or raise NotConnectedError

                #set updated field only if the core properties have changed
                if !fault? && !synced_core?
                    #set updated field
                    @updated_date = Time.now.utc.iso8601
                end

                #only save it if it's not a fault, if it hasnt already been saved and if someone holds a ref to it
                if !fault? && !synced?
                    verify or raise VerificationFailedError

                    _observe(:updated)
                    _notify_observer

                    Manager.messages.save(serialize)
                    did_sync

                    self
                else
                    nil
                end
            end

            def delete
                #record this
                _observe(:deleted)

                #tell observer
                _notify_observer

                #remove yourself from cache
                Manager.remove_from_cache(self.class.name, id)

                #remove yourself from the database
                Manager.messages.remove({:_id => BSON::ObjectId.from_string(id)})

                #zero self just to be safe
                initialize
            end

            #returns whether a user has read a message
            def user_read?(user_id)
                return false if user_id.nil?

                load_from_server if fault?

                @read.include?(user_id)
            end

            def set_user_read(user_id, did_read)
                load_from_server if fault?

                if did_read
                    if not user_read?(user_id)
                        _observe(:read, user_id)
                        @read.push(user_id) 
                    end
                else
                    @read.delete(user_id)
                end
            end

            def serialize
                {
                    :_id => BSON::ObjectId.from_string(@id),
                    :type => @type,
                    :payload => @payload,
                    :updatedDate => @updated_date,
                    :authorID => @author,
                    :read => @read,
                }
            end

            def serialize_core
                {
                    :_id => BSON::ObjectId.from_string(@id),
                    :type => @type,
                    :payload => @payload,
                    :authorID => @author,
                }
            end

            #makes sure that the object is good, before we save it to the db
            def verify#todo
                #if its a fault, then its a no for sure
                #otherwise make sure all the fields are the right type, and are initialized etc
                true
            end

        protected
            def _load_from_server(id)
                Manager.messages.find_one({:_id => BSON::ObjectId.from_string(id)})
            end

        private
            def _notify_observer
                #loop through changes array
                changes.uniq.each do |i|
                    #loop through all kv pairs in the hash
                    i.each do |k, v|
                        case k
                        when :created
                            Manager.no.created_message(id) if Manager.no.respond_to?(:created_message)
                        when :deleted
                            Manager.no.deleted_message(id) if Manager.no.respond_to?(:deleted_message)
                        when :updated
                            Manager.no.updated_message(id) if Manager.no.respond_to?(:updated_message)
                        when :read
                            Manager.no.user_read_message(id, v) if Manager.no.respond_to?(:user_read_message)
                        else
                            #noop
                        end
                    end
                end
                changes.clear
            end
        end
    end
end