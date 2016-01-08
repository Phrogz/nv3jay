class RB3Jay < Sinatra::Application
	get '/search' do
		fields = {
			"file"        => :file,
			"filename"    => :file,
			"artist"      => :artist,
			"album"       => :album,
			"albumartist" => :albumartist,
			"title"       => :title,
			"genre"       => :genre,
			"date"        => :date,
			"name"        => :title,
			"year"        => :date,
			"n"           => :title,
			"t"           => :title,
			"a"           => :artist,
			"A"           => :album,
			"b"           => :album,
			"y"           => :date,
			"g"           => :genre,
			"f"           => :file,
			nil           => :any
		}
	  query = params[:query]
		if !query || query.empty?
			[]
		else
			query.split(/\s+/).map do |piece|
				*field,str = piece.split(':')
				field = fields[field.first]
				if field==:date && str[RB3Jay::YEAR_RANGE]
					_,y1,y2 = str.match(RB3Jay::YEAR_RANGE).to_a
					y1,y2 = y1.to_i,y2.to_i
					y1,y2 = y2,y1 if y1>y2
					y1.upto(y2).flat_map{ |y| @mpd.where(date:y) }
				else
					@mpd.where( {field=>str}, {limit:RB3Jay::MAX_RESULTS} )
				end
			end
			.inject(:&)
			.uniq[0..RB3Jay::MAX_RESULTS]
			.sort_by(&RB3Jay::SONG_ORDER)
			.map(&:details)
		end.to_json
	end
end
