require_relative 'login_service/sparql_queries.rb'

## Monkeypatch sparql-client with mu-auth-sudo header
require_relative 'auth_extensions/sudo'
include AuthExtensions::Sudo

###
# Vocabularies
###

MU_ACCOUNT = RDF::Vocabulary.new(MU.to_uri.to_s + 'account/')
MU_SESSION = RDF::Vocabulary.new(MU.to_uri.to_s + 'session/')
BESLUIT =  RDF::Vocabulary.new('http://data.vlaanderen.be/ns/besluit#')

###
# POST /sessions
#
# Body
# data: {
#   relationships: {
#     account:{
#       data: {
#         id: "account_id",
#         type: "accounts"
#       }
#     }
#   },
#   type: "sessions"
# }
# Returns 201 on successful login
#         400 if session header is missing
#         400 on login failure (incorrect user/password or inactive account)
###
post '/sessions/' do
  content_type 'application/vnd.api+json'


  ###
  # Validate headers
  ###
  validate_json_api_content_type(request)

  session_uri = session_id_header(request)
  error('Session header is missing') if session_uri.nil?

  rewrite_url = rewrite_url_header(request)
  error('X-Rewrite-URL header is missing') if rewrite_url.nil?


  ###
  # Validate request
  ###

  data = @json_body['data']

  validate_resource_type('sessions', data)
  error('Id paramater is not allowed', 400) if not data['id'].nil?
  error('exactly one account should be linked') unless data.dig("relationships","account", "data", "id")
  error('exactly one group should be linked') unless data.dig("relationships","group", "data", "id")


  ###
  # Validate login
  ###

  result = select_account(data["relationships"]["account"]["data"]["id"])
  error('account not found.', 400) if result.empty?
  account = result.first

  group_id = data["relationships"]["group"]["data"]["id"]
  result = select_group(group_id)
  error('group not found', 400) if result.empty?
  group = result.first

  result = select_roles(data["relationships"]["account"]["data"]["id"])
  error('roles not found', 400) if result.empty?
  roles = result.map { |r| r[:role].to_s }

  ###
  # Remove old sessions
  ###
  remove_old_sessions(session_uri)

  ###
  # Insert new session
  ###
  session_id = generate_uuid()
  insert_new_session_for_account(account[:uri].to_s, session_uri, session_id, group[:group].to_s, group_id, roles)

  status 201
  headers['mu-auth-allowed-groups'] = 'CLEAR'
  {
    links: {
      self: rewrite_url.chomp('/') + '/current'
    },
    data: {
      type: 'sessions',
      id: session_id,
      attributes: {
        roles: roles
      }
    },
    relationships: {
      account: {
        links: {
          related: "/accounts/#{data['relationships']['account']['data']['id']}"
        },
        data: {
          type: "accounts",
          id: data['relationships']['account']['data']['id']
        }
      },
      group: {
        links: {
          related: "/groups/#{data['relationships']['group']['data']['id']}"
        },
        data: {
          type: "groups",
          id: data['relationships']['group']['data']['id']
        }
      }
    }
  }.to_json
end


###
# DELETE /sessions/current
#
# Returns 204 on successful logout
#         400 if session header is missing or session header is invalid
###
delete '/sessions/current/?' do
  content_type 'application/vnd.api+json'

  ###
  # Validate session
  ###

  session_uri = session_id_header(request)
  error('Session header is missing') if session_uri.nil?


  ###
  # Get account
  ###

  result = select_account_by_session(session_uri)
  error('Invalid session') if result.empty?
  account = result.first[:account].to_s


  ###
  # Remove session
  ###

  delete_current_session(account)

  status 204
  headers['mu-auth-allowed-groups'] = 'CLEAR'
end


###
# GET /sessions/current
#
# Returns 200 if current session exists
#         400 if session header is missing or session header is invalid
###
get '/sessions/current/?' do
  content_type 'application/vnd.api+json'

  ###
  # Validate session
  ###

  session_uri = session_id_header(request)
  error('Session header is missing') if session_uri.nil?


  ###
  # Get account
  ###

  result = select_account_by_session(session_uri)
  error('Invalid session') if result.empty?
  session = result.first

  rewrite_url = rewrite_url_header(request)

  status 200
  {
    links: {
      self: rewrite_url.chomp('/') + '/current'
    },
    data: {
      type: 'sessions',
      id: session[:session_uuid],
      attributes: {
        roles: session[:roles].to_s.split(',')
      }
    },
    relationships: {
      account: {
        links: {
          related: "/accounts/#{session[:account_uuid]}"
        },
        data: {
          type: "accounts",
          id: session[:account_uuid]
        }
      },
      group: {
        links: {
          related: "/groups/#{session[:group_uuid]}"
        },
        data: {
          type: "groups",
          id: session[:group_uuid]
        }
      }
    }
  }.to_json
end


###
# GET /accounts
#
# Returns 200 with list of mock accounts
#        
###
get '/accounts/?' do
  content_type 'application/vnd.api+json'

  ###
  # Get accounts
  ###

  result = select_accounts()

  base_url = request.base_url
  groups = result.map do |res| 
     {
            attributes: {
              name: res[:group_name]
            },
            type: 'groups',
            id: res[:group_uuid],
            relationships: {}
     }
    end
  persons = result.map do |res|
         
            {
            attributes: {
              'family-name': res[:user_familyame],
              'first-name': res[:user_firstname]
            },
            id: res[:user_uuid],
            type: 'users',
            relationships: {
              accounts: {
                related: base_url.chomp('/') + '/users/' + res[:user_uuid] + '/accounts'
              },
              groups: {
                data: [
                  {
                    type: 'groups',
                    id: res[:group_uuid]
                  }
                ],
                links: {
                  related: base_url.chomp('/') + '/users/' + res[:user_uuid] + '/groups'
                }
              }
            }
          } 
        end
  data = result.map do |res|
      {
        type: 'accounts',
        id: res[:account_uuid],
        attributes: {
          provider: res[:account_provider]
        },
        relationships: {
          user: {
            links: {
                related: base_url.chomp('/') + '/accounts/' + res[:account_uuid] + '/user'
            },
            data: {
              id: res[:user_uuid],
              type: 'users'
            }
          }
        }
      }
    end
  status 200
  {
    links: {
      self: base_url.chomp('/') + '/accounts'
    },
    data: data,
   included: groups + persons
        }.to_json
end

###
# Helpers
###

helpers LoginService::SparqlQueries
