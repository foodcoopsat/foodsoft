class Api::V1::PickupController < Api::V1::BaseController

  #@@time_now = Time.now               # for real database
  @@time_now = Time.new(2025, 12, 17)  # for local test database
  
  def index
    ordergroup_id = params.fetch(:ordergroup_id, nil)
    ordergroup_id = current_user.ordergroup.id unless ordergroup_id 
    # logger.debug "orderog-id:  #{ordergroup_id}"

    base_scope = GroupOrder
      .includes(group_order_articles: { order_article: :article },
                order: :supplier, 
                order: :comments)
      .references(:orders)
      .where(ordergroup_id: ordergroup_id)
      .limit(200)

    group_orders = base_scope.where(
      orders: {
        state: "open",
        pickup: nil, # z.B. Leergut Rückgabe
        ends: @@time_now.weeks_ago(1)..@@time_now.next_year
      }
    ).or(
      base_scope.where(
        orders: {
          state: "open",
          supplier_id: nil, # Lager
          ends: @@time_now.weeks_ago(1)..@@time_now.next_year
        }
      )  
    ).or(
      base_scope.where(
        orders: {
          state: %w[finished received closed],
          pickup: @@time_now.weeks_ago(params.fetch(:weeks, 5))..@@time_now.weeks_ago(-1)
        }
      )
    )

    render json: # group_orders, each_serializer: PickupOGSerializer
    {
      group_orders: group_orders.map { |go|
        {
          id: go.id, 
          ends: go.order.ends,
          pickup: go.order.pickup,
          state: go.order.state,
          order_id: go.order.id,
          name: go.order.name,
          supplier_note: go.order.supplier ? go.order.supplier.note : ""  ,
          articles: go.group_order_articles.map { |goa|
            { id: goa.id,
              name: goa.order_article.article.name,
              unit: goa.order_article.article.unit,
              price: goa.order_article.article.price,
              deposit: goa.order_article.article.deposit,
              ordered: goa.quantity,
              tolerance: goa.tolerance, 
              received: goa.result,   }
          }
        }
      }         
    }
  end



  def show
    result = params.require(:id) 
    if result == "users" 
      render json: User.undeleted 
      {
        users: User.undeleted.map { |user|
          { 
            id: user.id, 
            name: user.name,
            email: user.email, 
            locale: user.locale, 
            ordergroup_name: user.ordergroup_name, 
            ordergroup_id: user.ordergroup ? user.ordergroup.id : -1,
          }
        }
      }
    elsif result == "orders"
      order_ids = params.fetch(:ids, "").split(",").map(&:to_i)
      if order_ids.any?
        #logger.debug "order-ids:  #{order_ids}"
        orders = Order.where(id: order_ids).includes(
          :comments, 
          order_articles:  { group_order_articles: { group_order: :ordergroup }}
        ) 
        render json: #orders,  each_serializer: PickupAllOgSerializer
        { 
          orders: orders.map { |order|
            { 
              id: order.id,
              name: order.name,
              state: order.state,
              ends: order.ends,
              pickup: order.pickup,
              supplier_note: order.supplier ? order.supplier.note : ""  ,
              articles: order.order_articles.map { |oa|
                oa.group_order_articles.any? ? { 
                  id: oa.id,
                  name: oa.article.name,
                  unit: oa.article.unit,
                  price: oa.article.price,
                  deposit: oa.article.deposit,
                  grouporders: oa.group_order_articles.map { |goa|
                    { 
                      id: goa.id,
                      ordergroup_name: (goa.group_order.ordergroup ? goa.group_order.ordergroup.name : "none"),
                      ordered: goa.quantity,
                      tolerance: goa.tolerance, 
                      received: goa.result, 
                    }
                  }
                } : nil 
              }.compact, # remove nil elements
              comments: order.comments,
            }
          }
        }
      else # no order ids specified   
        orders = Order.where(
            state: %w[finished received closed],
            pickup: @@time_now.weeks_ago(params.fetch(:weeks, 5))..@@time_now.weeks_ago(-1)
        ).includes(:supplier)
        render json: # orders
        {
          orders: orders.map { |order|
            { # only overview for order selection, no article details
              id: order.id,
              name: order.name,
              state: order.state,
              ends: order.ends,
              pickup: order.pickup,
              supplier_note: order.supplier ? order.supplier.note : ""  
            }
          }
        }
      end
    end
  end




  def update
    order_id = params.require(:id)
    comment = params.fetch(:comment, "")
    if comment && order_id
      Order.transaction do
        logger.debug "  order id: #{order_id}"
        order = Order.find(order_id)
        order.comments.create(user: current_user, text:comment)
      end
    end
    
    GroupOrderArticle.transaction do
      params.fetch(:updates, {}).each do |article_id, property_updates| 
        logger.debug "update #{article_id} => #{property_updates}"
        goa = GroupOrderArticle.find(article_id)
        property_updates.each do |property, value|
          logger.debug "update_attribute #{property} => #{value}"
          goa.update_attribute(property, value) # allows updates for closed orders, skips validation
          if property == "result"
            total = GroupOrderArticle.where(order_article_id: goa.order_article_id).sum(:result)
            logger.debug "  result total: #{total}"
            goa.order_article.update!(units_received: total)  
          end
        end
      end
    end
  end
end
