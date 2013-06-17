# encoding: UTF-8

# messages.rb
# Goonbee
#
# Created by Luka Mirosevic on 27/04/2013.
# Copyright (c) 2013 Goonbee. All rights reserved.

#foo implement object verification

class Hash#foo factor this out into a GBToolbox module
	def symbolize_keys
		_symbolize_keys(self)
	end

	def _symbolize_keys(hash)
		hash.inject({}){|result, (key, value)|
			new_key = case key
				          when String then key.to_sym
				          else key
			          end
			new_value = case value
				            when Hash then _symbolize_keys(value)
				            else value
			            end
			result[new_key] = new_value
			result
		}
	end


	#def symbolize_keys(hash)
	#	hash.keys.each do |key|
	#		hash[(key.to_sym rescue key) || key] = hash.delete(key)
	#	end
	#end
	#
	#def symbolize_keys_deep!
	#	self.inject({}) do |result, (key, value)|
	#		new_key = case key
	#			when String then key.to_sym
	#			else key
	#			end
	#		new_value = case value
	#			when Hash then symbolize_keys(value)
	#			else value
	#			end
	#		result[new_key] = new_value
	#		result
	#	end
	#end
end

module Syncable
	attr_accessor :last_hash

	def synced?
		last_hash == serialize.hash
	end

	def did_sync
		last_hash = serialize.hash
	end
end

module Goonbee
	module Messages
		require 'mongo'
		require 'json'
		require 'bson'
		require 'time'

		class Manager
			class << self
				attr_reader :db, :messages, :collections, :connected
				attr_accessor :notifications_object
				alias_method :register_notifications_object, :notifications_object=
				alias_method :no, :notifications_object

				def connect(database)
					@db = database
					@messages = @db.collection('messages')
					@collections = @db.collection('collections')
					@connected = true
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
				Manager.connected or raise('Manager not connected')

				if id && (document = _load_from_server(id))
					initialize(document.symbolize_keys.merge({:fault => false}))
					did_sync
					self
				else
					raise("No such item for id: #{id}")
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

			def save
				Manager.connected or raise('Manager not connected')

				#only save it if it's not a fault
				if !fault? && !synced_deep?
					#set updated field
					@updated_date = Time.now.utc.iso8601

					#first verify the collection
					verify or raise('Collection could not be verified, did NOT save')

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

			def serialize_public
				load_from_server

				{
					:collectionID => @id,
					:type => @type,
					:meta => @meta,
					:messages => @messages.map {|i| i.serialize_public},
					:createdDate => @created_date,
					:updatedDate => @updated_date,
				}
			end

			def serialize_public_for_user(user)
				load_from_server

				{
					:collectionID => @id,
					:type => @type,
					:meta => @meta,
					:messages => @messages.map {|i| i.serialize_public_for_user(user)},
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

			def initialize(opts={})
				super

				@id = (opts[:_id ] ? opts[:_id].to_s : false) || opts[:id]
				@type = opts[:type] || nil
				@payload = opts[:payload] || nil
				@updated_date = opts[:updatedDate] || nil
				@author = opts[:author] || nil
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
				Manager.connected or raise('Manager not connected')

				#only save it if it's not a fault, if it hasnt already been saved and if someone holds a ref to it
				if !fault? && !synced?
					@updated_date = Time.now.utc.iso8601

					verify or raise('Message could not be verified, did NOT save')

					_observe(:updated)
					_notify_observer

					Manager.messages.save(serialize)
					did_sync

					self
				else
					nil
				end
			end

			#returns whether a user has read a message
			def user_read?(user)
				load_from_server if fault?

				@read.include?(user)
			end

			def set_user_read(user_id, did_read)
				load_from_server if fault?

				if did_read
					unless user_read?(user_id)
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
					:author => @author,
					:read => @read,
				}
			end

			def serialize_public
				load_from_server

				{
					:messageID => @id,
					:type => @type,
					:payload => @payload,
					:updatedDate => @updated_date,
					:author => @author,
				}
			end

			def serialize_public_for_user(user)
				return serialize_public if user.nil?

				load_from_server

				{
					:messageID => @id,
					:type => @type,
					:payload => @payload,
					:updatedDate => @updated_date,
					:author => @author,
					:read => user_read?(user),
				}
			end

			#makes sure that the object is good, before we save it to the db
			def verify#todo
				#if its a fault, then its a no for sure
				#otherwise make sure all the fields are the right type, and are initialized etc
				true#todo
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