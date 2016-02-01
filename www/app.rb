%w[ eventmachine thin sinatra faye sequel set
	  rack/session/moneta ruby-mpd json time ].each{ |lib| require lib }

require_relative 'environment'
require_relative 'helpers/ruby-mpd-monkeypatches'

def run!
	EM.run do
		Faye::WebSocket.load_adapter('thin')
		server = Faye::RackAdapter.new(mount:'/', timeout:25)
		rb3jay = RB3Jay.new( server )

		dispatch = Rack::Builder.app do
			map('/'){     run rb3jay }
			map('/faye'){ run server }
		end

		ENV['RACK_ENV'] = 'production'

		Rack::Server.start({
			app:     dispatch,
			Host:    ENV['RB3JAY_HOST'],
			Port:    ENV['RB3JAY_PORT'],
			server:  'thin',
			signals: false,
		})
	end
end

class RB3Jay < Sinatra::Application
	SKIP_PERCENT = 0.6
	use Rack::Session::Moneta, key:'rb3jay.session', path:'/', store: :LRUHash

	configure do
		set :threaded, false
	end

	def initialize( faye_server )
		super()
		@server = faye_server
		@mpd = MPD.new( ENV['MPD_HOST'], ENV['MPD_PORT'] )
		@mpd.connect
		@faye = Faye::Client.new("http://#{ENV['RB3JAY_HOST']}:#{ENV['RB3JAY_PORT']}/faye")
		watch_for_subscriptions
		watch_for_changes
		require_relative 'model/init'
		@db = connect_to( ENV['MPD_STICKERS'] )
	end

	def watch_for_subscriptions
		@server.on(:subscribe) do |client_id, channel|
			if user=channel[/startup-(.+)/,1]
				@faye.publish channel, {
					playlists:playlists,
					myqueue:playlist_songs_for(user),
					upnext:up_next,
					status:mpd_status
				}
			end
		end
	end

	def watch_for_changes
		watch_status
		watch_playlists
		watch_player
		watch_upnext
	end

	def watch_status
		@previous_song = nil
		@previous_time = nil
		EM.add_periodic_timer(0.5) do
			if (info=mpd_status) != @last_status
				@last_status = info
				send_status( info )
				if info[:songid]
					if !@previous_song
						@previous_song = @mpd.song_with_id(info[:songid])
					elsif @previous_song.id != info[:songid]
						if @previous_time / @previous_song.track_length > SKIP_PERCENT
							stickers = @mpd.list_stickers 'song', @previous_song.file
							record_event 'play', stickers['added-by']
						end
						@previous_song = @mpd.song_with_id(info[:songid])

						# Remove the newly-playing song from the playist it game from
						if user=@mpd.list_stickers('song', @previous_song.file)['added-by']
							if queue=@mpd.playlists.find{ |pl| pl.name=="user-#{user}" }
								if index=queue.songs.index{ |song| song.file==@previous_song.file }
									queue.delete index
									send_playlist queue
								else
									p queue.songs
								end
							end
						end
					end
					@previous_time = info[:elapsed]
				end
			end
		end
	end

	def record_event( event, user=nil )
		if @previous_song
			@db[:song_events] << {
				user:     user,
				event:    event,
				uri:      @previous_song.file,
				duration: @previous_time,
				when:     Time.now
			}
		end
	end

	def watch_playlists
		EM.defer(
			->( ){ idle_until 'stored_playlist'    },
			->(_){
				send_playlists
				recalc_up_next
				watch_playlists
			}
		)
	end

	def watch_upnext
		EM.defer(
			->( ){ idle_until 'playlist', 'database' },
			->(_){ send_next; watch_upnext           }
		)
	end

	def watch_player
		EM.defer(
			->( ){ idle_until 'player' },
			->(_){
				# recalc_up_next
				watch_player
			}
		)
	end

	def idle_until(*events)
		# This is a synchronous blocking call, that will
		# return when one of the events finally occurs
		`mpc -h #{ENV['MPD_HOST']} -p #{ENV['MPD_PORT']} idle #{events.join(' ')}`
	end

	before{ content_type :json }

	get '/' do
		content_type :html
		send_file File.expand_path('index.html',settings.public_folder)
	end

	helpers do
		def mpd_status
			current = @mpd.current_song
			@mpd.status.merge(file:current && current.file)
		end
		def send_status( info=mpd_status )
			@faye.publish '/status', info
		end
		def up_next
			@mpd.queue.slice(0,ENV['RB3JAY_LISTLIMIT'].to_i).map(&:summary)
		end
		def send_next( songs=up_next )
			@faye.publish '/next', songs
		end
		def playlists
			@mpd.playlists.map(&:name).grep(/^(?!user-)/).sort
		end
		def playlist_songs_for(user)
			pl = @mpd.playlists.find{ |pl| pl.name=="user-#{user}" }
			pl ? pl.songs.map(&:summary) : []
		end
		def send_playlists( lists=playlists )
			@faye.publish '/playlists', playlists
		end
		def send_playlist( list )
			name = list.name.sub('user-','')
			@faye.publish "/playlist/#{name}", list.songs.map(&:summary)
		end
		def add_to_upnext( songs, priority=0 )
			start = @mpd.playing? ? 1 : 0
			index = nil
			@mpd.queue[start..-1].find.with_index{ |song,i| prio = song.prio && song.prio.to_i || 0; index=i+start if prio<priority }
			song_ids = Array(songs).reverse.map{ |path| @mpd.addid(path,index) }
			@mpd.song_priority(priority,{id:song_ids}) if priority>0
		end
	end

	# We do not need to send a response after these because
	# updates are automatically pushed based on changes.
	post('/play'){ @mpd.play                                    ; '"ok"' }
	post('/paws'){ @mpd.pause=true                              ; '"ok"' }
	post('/skip'){ @mpd.next; record_event('skip',params[:user]); '"ok"' }
	post('/seek'){ @mpd.seek params[:time].to_f                 ; '"ok"' }
	post('/volm'){ @mpd.volume = params[:volume].to_i           ; '"ok"' }

	require_relative 'routes/ratings'
	require_relative 'routes/songs'
	require_relative 'routes/myqueue'
	require_relative 'routes/upnext'
end

run!
