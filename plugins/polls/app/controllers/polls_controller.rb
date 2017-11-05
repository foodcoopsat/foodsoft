class PollsController < ApplicationController
  before_filter -> { require_plugin_enabled FoodsoftPolls }

  def index
    #@open_polls = Poll.open
    @polls = Poll.page(params[:page]).per(@per_page)
  end

  def show
    @poll = Poll.find(params[:id])
  end

  def new
    @poll = Poll.new
  end

  def create
    @poll = Poll.new(params[:poll])
    @poll.created_by = current_user

    if @poll.save
      redirect_to @poll, notice: t('.notice')
    else
      render action: 'edit'
    end
  end

  def edit
    @poll = Poll.find(params[:id])

    if @poll.created_by != current_user && !current_user.role_admin?
      redirect_to polls_path, alert: t('.no_right')
    end
  end

  def update
    @poll = Poll.find(params[:id])

    if @poll.created_by != current_user && !current_user.role_admin?
      redirect_to polls_path, alert: t('.no_right')
    elsif @poll.update_attributes(params[:poll])
      redirect_to @poll, notice: t('.notice')
    else
      render action: 'edit'
    end
  end

  def destroy
    @poll = Poll.find(params[:id])

    if @poll.created_by != current_user && !current_user.role_admin?
      redirect_to polls_path, alert: t('.no_right')
    else
      @poll.destroy
      redirect_to polls_path, notice: t('.notice')
    end
  rescue => error
    redirect_to polls_path, alert: t('.error', error: error.message)
  end

  def vote
    @poll = Poll.find(params[:id])

    if @poll.one_vote_per_ordergroup
      ordergroup = current_user.ordergroup
      return redirect_to polls_path, alert: t('.no_ordergroup') unless ordergroup
      attributes = { ordergroup: ordergroup }
    else
      attributes = { user: current_user }
    end

    redirect_to @poll, alert: t('.no_right') unless @poll.user_can_vote?(current_user)

    @poll_vote = @poll.poll_votes.where(attributes).first_or_initialize

    if request.post?
      @poll_vote.update!(note: params[:note], user: current_user)

      if @poll.single_select?
        choices = { params[:choice] => '1' }
      else
        choices = params[:choices] || {}
      end

      @poll_vote.poll_choices = choices.map do |choice, value|
        poll_choice = @poll_vote.poll_choices.where(choice: choice).first_or_initialize
        poll_choice.update!(value: value)
        poll_choice
      end

      redirect_to @poll
    end
  end
end
