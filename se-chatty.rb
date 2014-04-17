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
	end

	def send_message room_number, message = nil
		if !message
			message = room_number
			room_number = @default_room_number
		end
		@agent.post("http://chat.#{@sitename}/chats/#{room_number}/messages/new", [['text', message], ['fkey', @fkey]])
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
end

# for this example, I'm using http://chat.stackexchange.com/rooms/11540/charcoal-hq
sec = SEChatty.new 'stackexchange.com', 'INSERT EMAIL HERE', 'INSERT PASSWORD HERE', 11540
# sec.send_message "Example message"
sec.get_messages {|event|
  # this is called when a message arrives (whether it be a user entering the room, an edit, a star, etc.)
	p event.data
}
