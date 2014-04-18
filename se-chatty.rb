require 'mechanize'
require 'faye/websocket'
require 'eventmachine'
require 'json'

class SEChatty
	def initialize sitename, email, password, default_room_number = 1
		agent = Mechanize.new
		agent.agent.http.verify_mode = OpenSSL::SSL::VERIFY_NONE

		login_form = agent.get('https://openid.stackexchange.com/account/login').forms.first
		login_form.email = email
		login_form.password = password
		agent.submit login_form, login_form.buttons.first
		
		site_login_form = agent.get('https://' + sitename + '/users/login').forms.last
		site_login_form.openid_identifier = 'https://openid.stackexchange.com/'
		agent.submit site_login_form, site_login_form.buttons.last

		chat_login_form = agent.get('http://stackexchange.com/users/chat-login').forms.last
		agent.submit chat_login_form, chat_login_form.buttons.last

		@fkey = agent.get('http://chat.' + sitename + '/chats/join/favorite').forms.last.fkey
		@agent = agent
		@sitename = sitename
		@default_room_number = default_room_number
		@previous_message = ''
	end

	def send_message message, room_number = @default_room_number
		message += '.' if message == @previous_message
		loop {
			success = false
			begin
				resp = @agent.post("http://chat.#{@sitename}/chats/#{room_number}/messages/new", [['text', message.slice(0, 500)], ['fkey', @fkey]]).body
				success = JSON.parse(resp)['id'] != nil
			rescue Mechanize::ResponseCodeError => e
				puts "Error: #{e.inspect}"
			end
			break if success
			puts 'sleeping'
			sleep 3
		}
		@previous_message = message
	end

	def get_messages room_number = @default_room_number
		ws_url = JSON.parse(@agent.post("http://chat.#{@sitename}/ws-auth", [['roomid', room_number], ['fkey', @fkey]]).body)['url']
		ws_url += '?l=' + JSON.parse(@agent.post("http://chat.#{@sitename}/chats/#{room_number}/events", [['fkey', @fkey]]).body)['time'].to_s
		EM.run {
			ws = Faye::WebSocket::Client.new(ws_url, nil, {
				headers: {'Origin' => "http://chat.#{@sitename}"}
			})

			ws.on :message do |event|
				yield event
			end
		}
	end

	module Event
		MessagePosted = 1
		MessageEdited = 2
		UserEntered = 3
		UserLeft = 4
		RoomNameChanged = 5
		MessageStarred = 6
		DebugMessage = 7
		UserMentioned = 8
		MessageFlagged = 9
		MessageDeleted = 10
		FileAdded = 11
		ModeratorFlag = 12
		UserSettingsChanged = 13
		GlobalNotification = 14
		AccessLevelChanged = 15
		UserNotification = 16
		Invitation = 17
		MessageReply = 18
		MessageMovedOut = 19
		MessageMovedIn = 20
		TimeBreak = 21
		FeedTicker = 22
		UserSuspended = 29
		UserMerged = 30
	end
end

# for this example, I'm using http://chat.stackexchange.com/rooms/13972/bot-testing-room
sec = SEChatty.new 'stackexchange.com', 'INSERT EMAIL HERE', 'INSERT PASSWORD HERE', 13972
sec.send_message 'Bot initialized'
sec.get_messages {|event|
	JSON.parse(event.data).each do |room, data|
		room_number = room.match(/\d+/)[0]
		if data['e']
			data['e'].each do |e|
				p e
				next if e['user_id'] == 110309 # my chatbot's id
				case e['event_type']
				when SEChatty::Event::MessagePosted, SEChatty::Event::MessageEdited
					sec.send_message ":#{e['message_id']} Hello! That message was \"#{e['content']}\" and your username is #{e['user_name']}." if e['content'] =~ /hello/i
				when SEChatty::Event::UserEntered
					sec.send_message "Hi #{e['user_name']}!"
				when SEChatty::Event::UserLeft
					sec.send_message "Bye #{e['user_name']}!"
				when SEChatty::Event::RoomNameChanged
					sec.send_message "I #{e['content'].sum % 2 == 0 ? "don't " : ''}like that new name and description."
				when SEChatty::Event::MessageStarred
					sec.send_message "#{e['user_name']} starred that."
				when SEChatty::Event::MessageDeleted
					sec.send_message ":#{e['message_id']} (removed) to you too."
				end
			end
		end
	end
}
at_exit { sec.send_message "I've been killed!" }
