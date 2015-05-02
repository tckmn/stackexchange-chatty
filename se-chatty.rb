#!/usr/bin/ruby

require 'mechanize'
require 'faye/websocket'
require 'eventmachine'
require 'json'

email = open('email.txt').read.chomp
password = open('password.txt').read.chomp
userid = open('userid.txt').read.to_i

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

        # start the rate-limit thread
        @rate_limit = Thread.new {
            loop {
                sleep 7.5
                @rate_limit_count = 0
            }
        }
        @rate_limit_count = 0
    end

    def send_message message, room_number = @default_room_number
        return if message == @previous_message # prevent duplicate messages

        # rate limit ftw!
        message = 'Rate limit reached.' if @rate_limit_count == 5
        return if @rate_limit_count > 5

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
        @rate_limit_count += 1
    end

    def reply e, message
        if message =~ /^[^ ]/
            self.send_message ":#{e['message_id']} #{message}", e['room_id']
        else
            self.send_message message, e['room_id']
        end
    end

    def get_messages room_number = @default_room_number
        ws_url = JSON.parse(@agent.post("http://chat.#{@sitename}/ws-auth", [['roomid', room_number], ['fkey', @fkey]]).body)['url']
        ws_url += '?l=' + JSON.parse(@agent.post("http://chat.#{@sitename}/chats/#{room_number}/events", [['fkey', @fkey]]).body)['time'].to_s
        Thread.new {
            EM.run {
                ws = Faye::WebSocket::Client.new(ws_url, nil, {
                    headers: {'Origin' => "http://chat.#{@sitename}"}
                })

                ws.on :message do |event|
                    yield event
                end
            }
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

# for this example, I'm using PPCG's chat room
sec = SEChatty.new 'stackexchange.com', email, password, 240
prefix = '!'
#sec.send_message "Bot initialized. Type #{prefix}help for help."
cmds = {
    help: ->a{
        sec.send_message "Type #{prefix}listcommands to list all commands that the chatbot can execute."
    },
    listcommands: ->a{
        sec.send_message "List of commands: #{cmds.keys * ', '}"
    }
}
unknown_cmd = ->cmdname, a{
    sec.send_message "Unknown command `#{cmdname}`."
}
sec.get_messages {|event|
    JSON.parse(event.data).each do |room, data|
        room_number = room.match(/\d+/)[0]
        if data['e']
            data['e'].each do |e|
                p e
                next if e['user_id'] == userid # my chatbot's id
                case e['event_type']
                when SEChatty::Event::MessagePosted, SEChatty::Event::MessageEdited
                    e['content'] = CGI.unescapeHTML e['content']
                    if e['content'].start_with? prefix
                        cmd = e['content'].sub prefix, ''
                        cmdname, args = (cmd.empty? ? '' : cmd.split(' ', 2))
                        cmdfunc = cmds[cmdname.to_sym]
                        cmdfunc ? cmdfunc[args] : unknown_cmd[cmdname, args]
                    end
                when SEChatty::Event::UserEntered
                    #sec.send_message "Hi #{e['user_name']}!"
                when SEChatty::Event::UserLeft
                    #sec.send_message "Bye #{e['user_name']}!"
                when SEChatty::Event::RoomNameChanged
                    #sec.send_message "I #{e['content'].sum % 2 == 0 ? "don't " : ''}like that new name and description."
                when SEChatty::Event::MessageStarred
                    #sec.send_message "#{e['user_name']} starred that."
                when SEChatty::Event::MessageDeleted
                    #sec.send_message "(removed) to you too, #{e['user_name']}."
                end
            end
        end
    end
}
Signal.trap('SIGINT') {
    #sec.send_message 'Bot killed manually'
    exit
}
sleep
