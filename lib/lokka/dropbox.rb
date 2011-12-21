require 'dropbox_sdk'

# If we already have an authorized DropboxSession, returns a DropboxClient.
def get_db_client
  if session[:authorized_db_session]
    db_session = DropboxSession.deserialize(session[:authorized_db_session])
    begin
      return DropboxClient.new(db_session, :dropbox)
    rescue DropboxAuthError => e
      # The stored session didn't work.  Fall through and start OAuth.
      session[:authorized_db_session].delete
    end
  end
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
          return "Exception in OAuth step 1: #{h e}"
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
          return "Error in OAuth step 2: Couldn't find OAuth state in session."
        end
        db_session = DropboxSession.deserialize(ser)

        # OAuth Step 3: Get an access token from Dropbox.
        begin
          db_session.get_access_token
        rescue DropboxError => e
          return "Exception in OAuth step 3: #{h e}"
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
          account_info = db_client.account_info
        rescue DropboxAuthError => e
          session.delete(:authorized_db_session)  # An auth error means the db_session is probably bad
          return "Dropbox auth error: #{h e}"
        rescue DropboxError => e
          if e.http_response.code == '404'
            return "Path not found: #{h path}"
          else
            return "Dropbox API error:<br /><pre>#{h e.http_response}</pre>"
          end
        end

        @uid = account_info['uid']
        @is_dir = entry['is_dir']
        @path = entry['path']
        @contents = entry['contents']

        return 'You can only access to Public folder.' unless @path =~ /^\/Public/

        haml :"plugin/lokka-dropbox/views/list", :layout => :"admin/layout"
      end
    end
  end
end


