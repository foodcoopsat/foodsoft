module GroupOrderArticlesHelper
  # return an edit field for a GroupOrderArticle result
  def group_order_article_edit_result(goa)
    result = number_with_precision goa.result, strip_insignificant_zeros: true
    return result unless can_be_edited_in_place?(goa)

    simple_form_for goa, remote: true, html: { 'data-submit-onchange' => 'changed', class: 'delta-input' } do |f|
      fields_html = f.input_field :result, as: :delta, class: 'input-nano', data: { min: 0 }, id: "r_#{goa.id}", value: result
      if goa.new_record?
        fields_html += f.hidden_field :order_article_id
        fields_html += f.hidden_field :group_order_id
        fields_html += f.hidden_field :quantity
        fields_html += f.hidden_field :tolerance
      end

      fields_html
    end
  end

  private

  def can_be_edited_in_place?(goa)
    goa.group_order.order.finished? && (
      current_user.role_finance? ||
      (FoodsoftConfig[:use_self_service] && goa.group_order.ordergroup.member?(current_user))
    )
  end
end
