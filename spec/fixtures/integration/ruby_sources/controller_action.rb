# frozen_string_literal: true

class OrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_order, only: %i[show update destroy]

  def index
    orders = Order.active.recent
    render json: orders, status: :ok
  end

  def create
    order = Order.new(order_params)

    if order.save
      PaymentProcessor.new.process(order)
      NotificationJob.perform_later(order.id)
      render json: order, status: :created
    else
      render json: { errors: order.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    order.cancel!
    head :no_content
  end

  private

  def set_order
    @order = Order.find(params[:id])
  end

  def order_params
    params.require(:order).permit(:customer_id, :payment_method)
  end
end
