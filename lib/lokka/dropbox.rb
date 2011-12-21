require 'dropbox_sdk'

ACCESS_TYPE = :dropbox
PUBLIC_PATH = "http://dl.dropbox.com/u/385564/"

# If we already have an authorized DropboxSession, returns a DropboxClient.
def get_db_client
    if session[:authorized_db_session]
        db_session = DropboxSession.deserialize(session[:authorized_db_session])
        begin
            return DropboxClient.new(db_session, ACCESS_TYPE)
        rescue DropboxAuthError => e
            # The stored session didn't work.  Fall through and start OAuth.
            session[:authorized_db_session].delete
        end
    end
end

def render_folder(db_client, entry)
    # Provide an upload form (so the user can add files to this folder)
    out = "<form action='/upload' method='post' enctype='multipart/form-data'>"
    out += "<label for='file'>Upload file:</label> <input name='file' type='file'/>"
    out += "<input type='submit' value='Upload'/>"
    out += "<input name='folder' type='hidden' value='#{h entry['path']}'/>"
    out += "</form>"  # TODO: Add a token to counter CSRF attacks.
    # List of folder contents
    entry['contents'].each do |child|
        cp = child['path']      # child path
        cn = File.basename(cp)  # child name
        if (child['is_dir']) then cn += '/' end

        if entry['path'] =~ /^\/Public/ && !child['is_dir']
          out += "<div><a style='text-decoration: none' href='#{PUBLIC_PATH}#{h cp.gsub(/\/Public\//, '')}'>#{h cn}</a></div>"
        else
          out += "<div><a style='text-decoration: none' href='/admin/plugins/dropbox/list?path=#{h cp}'>#{h cn}</a></div>"
        end
    end

    html_page "Folder: #{entry['path']}", out
end

def render_file(db_client, entry)
    # Just dump out metadata hash
    html_page "File: #{entry['path']}", "<pre>#{h entry.pretty_inspect}</pre>"
end

def html_page(title, body)
    "<html>" +
        "<head><title>#{h title}</title></head>" +
        "<body><h1>#{h title}</h1>#{body}</body>" +
    "</html>"
end

module Lokka
  module Dropbox
    def self.registered(app)
      app.get '/admin/plugins/dropbox' do
        haml :"plugin/lokka-dropbox/views/index", :layout => :"admin/layout"
      end

      app.put '/admin/plugins/dropbox' do
        Option.dropbox_app_key = params['dropbox_app_key']
        Option.dropbox_app_secret = params['dropbox_app_secret']
        flash[:notice] = 'Updated.'
        redirect '/admin/plugins/dropbox'
      end

      # -------------------------------------------------------------------
      # OAuth stuff

      app.get '/admin/plugins/dropbox/oauth-start' do
          # OAuth Step 1: Get a request token from Dropbox.
          db_session = DropboxSession.new(Option.dropbox_app_key, Option.dropbox_app_secret)
          begin
              db_session.get_request_token
          rescue DropboxError => e
              return html_page "Exception in OAuth step 1", "<p>#{h e}</p>"
          end

          session[:request_db_session] = db_session.serialize

          # OAuth Step 2: Send the user to the Dropbox website so they can authorize
          # our app.  After the user authorizes our app, Dropbox will redirect them
          # to our '/oauth-callback' endpoint.
          auth_url = db_session.get_authorize_url url('/admin/plugins/dropbox/oauth-callback')
          redirect auth_url
      end

      app.get '/admin/plugins/dropbox/oauth-callback' do
          # Finish OAuth Step 2
          ser = session[:request_db_session]
          unless ser
              return html_page "Error in OAuth step 2", "<p>Couldn't find OAuth state in session.</p>"
          end
          db_session = DropboxSession.deserialize(ser)

          # OAuth Step 3: Get an access token from Dropbox.
          begin
              db_session.get_access_token
          rescue DropboxError => e
              return html_page "Exception in OAuth step 3", "<p>#{h e}</p>"
          end
          session.delete(:request_db_session)
          session[:authorized_db_session] = db_session.serialize
          redirect url('/admin/plugins/dropbox/list?path=/Public')
          # In this simple example, we store the authorized DropboxSession in the web
          # session hash.  A "real" webapp might store it somewhere more persistent.
      end

      app.get '/admin/plugins/dropbox/list' do
        # Get the DropboxClient object.  Redirect to OAuth flow if necessary.
        db_client = get_db_client
        unless db_client
            redirect url("/admin/plugins/dropbox/oauth-start")
        end

        # Call DropboxClient.metadata
        path = params[:path] || '/'
        begin
            entry = db_client.metadata(path)
        rescue DropboxAuthError => e
            session.delete(:authorized_db_session)  # An auth error means the db_session is probably bad
            return html_page "Dropbox auth error", "<p>#{h e}</p>"
        rescue DropboxError => e
            if e.http_response.code == '404'
                return html_page "Path not found: #{h path}", ""
            else
                return html_page "Dropbox API error", "<pre>#{h e.http_response}</pre>"
            end
        end

        @path = entry['path']
        @contents = entry['contents']

        # if entry['is_dir']
            haml :"plugin/lokka-dropbox/views/list", :layout => :"admin/layout"
            # render_folder(db_client, entry)
        # else
            # render_file(db_client, entry)
        # end
      end
    end
  end
end
